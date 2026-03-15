const std = @import("std");
const UiManager = @import("UiManager.zig").UiManager;
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const ActionRegistry = @import("ActionRegistry.zig").ActionRegistry;
const HudBinder = @import("HudBinder.zig").HudBinder;
const UiRenderer = @import("../renderer/vulkan/UiRenderer.zig").UiRenderer;
const GameState = @import("../GameState.zig");
const BlockState = @import("../world/WorldState.zig").BlockState;
const app_config = @import("../app_config.zig");
const Options = @import("../Options.zig");
const glfw = @import("../platform/glfw.zig");

const log = std.log.scoped(.UI);

pub const MAX_WORLDS: u8 = 32;
pub const MAX_NAME_LEN: u8 = 32;

pub const AppState = enum {
    title_menu,
    singleplayer_menu,
    create_world,
    controls_title,
    controls_pause,
    loading,
    playing,
    pause_menu,
    inventory,
    saving,

    pub fn isMenu(self: AppState) bool {
        return switch (self) {
            .title_menu, .singleplayer_menu, .create_world, .controls_title, .controls_pause, .pause_menu, .inventory => true,
            .loading, .playing, .saving => false,
        };
    }
};

pub const Action = enum { load_world, create_world, delete_world, resume_game, return_to_title, quit };

const ScreenType = enum {
    title,
    singleplayer,
    create_world,
    controls,
    pause,
    inventory,
};

pub const MenuController = struct {
    ui_manager: *UiManager,
    allocator: std.mem.Allocator,
    app_state: AppState = .title_menu,
    action: ?Action = null,

    world_names: [MAX_WORLDS][MAX_NAME_LEN]u8 = undefined,
    world_name_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
    world_count: u8 = 0,
    selection: u8 = 0,

    hud_binder: ?HudBinder = null,
    options: ?*Options = null,
    ui_renderer: ?*const UiRenderer = null,

    // Controls screen state
    rebinding_action: ?Options.Action = null,
    keybind_list_id: WidgetId = NULL_WIDGET,
    rebind_hint_id: WidgetId = NULL_WIDGET,
    keybind_button_ids: [Options.Action.count]WidgetId = .{NULL_WIDGET} ** Options.Action.count,
    tp_crosshair_cb_id: WidgetId = NULL_WIDGET,

    // Game state reference (set during updateInventory for action handlers)
    game_state: ?*GameState = null,

    // Inventory screen state
    inv_slot_ids: [GameState.HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.HOTBAR_SIZE, // hotbar row
    inv_main_ids: [GameState.INV_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.INV_SIZE, // 3x9 main
    inv_armor_ids: [GameState.ARMOR_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.ARMOR_SLOTS,
    inv_equip_ids: [GameState.EQUIP_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.EQUIP_SLOTS,
    inv_offhand_id: WidgetId = NULL_WIDGET,
    inv_player_viewport_id: WidgetId = NULL_WIDGET,
    cursor_item_id: WidgetId = NULL_WIDGET,
    // Entity renderer viewport (in UI coords), read by VulkanRenderer
    entity_viewport: [4]f32 = .{ 0, 0, 0, 0 },
    entity_visible: bool = false,
    player_rotation: f32 = 0.4,
    dragging_player: bool = false,
    drag_start_x: f32 = 0,

    coming_soon_modal_id: WidgetId = NULL_WIDGET,

    world_list_id: WidgetId = NULL_WIDGET,
    no_worlds_label_id: WidgetId = NULL_WIDGET,
    delete_confirm_id: WidgetId = NULL_WIDGET,
    delete_label_id: WidgetId = NULL_WIDGET,
    world_search_input_id: WidgetId = NULL_WIDGET,
    create_world_input_id: WidgetId = NULL_WIDGET,
    world_type_label_id: WidgetId = NULL_WIDGET,
    selected_world_type: @import("../world/WorldState.zig").WorldType = .normal,

    pub fn init(ui_manager: *UiManager, allocator: std.mem.Allocator) MenuController {
        var self = MenuController{
            .ui_manager = ui_manager,
            .allocator = allocator,
        };
        self.loadScreen(.title);
        return self;
    }

    // ============================================================
    // State machine
    // ============================================================

    pub fn transitionTo(self: *MenuController, new_state: AppState) void {
        const old = self.app_state;
        if (old == new_state) return;

        // Unload old screen
        if (screenTypeFor(old)) |st| {
            self.unloadScreen(st);
        }

        // Load new screen
        if (screenTypeFor(new_state)) |st| {
            self.loadScreen(st);
        }

        self.app_state = new_state;
    }

    fn screenTypeFor(state: AppState) ?ScreenType {
        return switch (state) {
            .title_menu => .title,
            .singleplayer_menu => .singleplayer,
            .create_world => .create_world,
            .controls_title, .controls_pause => .controls,
            .pause_menu => .pause,
            .inventory => .inventory,
            .loading, .playing, .saving => null,
        };
    }

    fn loadScreen(self: *MenuController, screen: ScreenType) void {
        const file = switch (screen) {
            .title => "title_menu.xml",
            .singleplayer => "singleplayer_menu.xml",
            .create_world => "create_world_menu.xml",
            .controls => "controls_menu.xml",
            .pause => "pause_menu.xml",
            .inventory => "inventory.xml",
        };
        if (self.ui_manager.loadScreenFromFile(file, self.allocator)) {
            switch (screen) {
                .title => self.cacheTitleWidgetIds(),
                .singleplayer => {
                    self.cacheSingleplayerWidgetIds();
                    self.refreshWorldList();
                },
                .create_world => {
                    self.cacheCreateWorldWidgetIds();
                    self.selected_world_type = .normal;
                },
                .controls => {
                    self.cacheControlsWidgetIds();
                    self.populateKeybindList();
                },
                .pause => {},
                .inventory => self.cacheInventoryWidgetIds(),
            }
        } else {
            log.err("Failed to load {s}", .{file});
        }
    }

    fn unloadScreen(self: *MenuController, screen: ScreenType) void {
        if (self.ui_manager.screen_count == 0) return;
        self.ui_manager.removeTopScreen();
        switch (screen) {
            .title => {
                self.coming_soon_modal_id = NULL_WIDGET;
            },
            .singleplayer => self.resetSingleplayerWidgetIds(),
            .create_world => {
                self.create_world_input_id = NULL_WIDGET;
                self.world_type_label_id = NULL_WIDGET;
            },
            .controls => self.resetControlsWidgetIds(),
            .pause => {},
            .inventory => self.resetInventoryWidgetIds(),
        }
    }

    /// Get the active menu screen tree (top of screen stack).
    fn menuTree(self: *MenuController) ?*WidgetTree {
        if (self.ui_manager.screen_count == 0) return null;
        const idx = self.ui_manager.screen_count - 1;
        if (!self.ui_manager.screens[idx].active) return null;
        return &self.ui_manager.screens[idx].tree;
    }

    // ============================================================
    // Widget ID caching
    // ============================================================

    fn cacheTitleWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.coming_soon_modal_id = tree.findById("coming_soon_modal") orelse NULL_WIDGET;
    }

    fn cacheSingleplayerWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.world_list_id = tree.findById("world_list") orelse NULL_WIDGET;
        self.no_worlds_label_id = tree.findById("no_worlds_label") orelse NULL_WIDGET;
        self.delete_confirm_id = tree.findById("delete_confirm") orelse NULL_WIDGET;
        self.delete_label_id = tree.findById("delete_label") orelse NULL_WIDGET;
        self.world_search_input_id = tree.findById("world_search_input") orelse NULL_WIDGET;
    }

    fn cacheCreateWorldWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.create_world_input_id = tree.findById("create_world_input") orelse NULL_WIDGET;
        self.world_type_label_id = tree.findById("world_type_label") orelse NULL_WIDGET;
    }

    fn cacheControlsWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.keybind_list_id = tree.findById("keybind_list") orelse NULL_WIDGET;
        self.rebind_hint_id = tree.findById("rebind_hint") orelse NULL_WIDGET;
        self.tp_crosshair_cb_id = tree.findById("tp_crosshair_cb") orelse NULL_WIDGET;

        // Sync checkbox state from options
        if (self.options) |opts| {
            if (self.tp_crosshair_cb_id != NULL_WIDGET) {
                if (tree.getData(self.tp_crosshair_cb_id)) |data| {
                    data.checkbox.checked = opts.third_person_crosshair;
                }
            }
        }
    }

    fn resetSingleplayerWidgetIds(self: *MenuController) void {
        self.world_list_id = NULL_WIDGET;
        self.no_worlds_label_id = NULL_WIDGET;
        self.delete_confirm_id = NULL_WIDGET;
        self.delete_label_id = NULL_WIDGET;
        self.world_search_input_id = NULL_WIDGET;
    }

    fn resetControlsWidgetIds(self: *MenuController) void {
        self.keybind_list_id = NULL_WIDGET;
        self.rebind_hint_id = NULL_WIDGET;
        self.tp_crosshair_cb_id = NULL_WIDGET;
        self.keybind_button_ids = .{NULL_WIDGET} ** Options.Action.count;
        self.rebinding_action = null;
    }

    fn cacheInventoryWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        const hover_col = Widget.Color.fromHex(0xFFFFFF22);
        inline for (0..GameState.HOTBAR_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("hotbar_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_slot_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
        }
        inline for (0..GameState.INV_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("inv_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_main_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
        }
        inline for (0..GameState.ARMOR_SLOTS) |i| {
            const name = comptime std.fmt.comptimePrint("armor_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_armor_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
        }
        inline for (0..GameState.EQUIP_SLOTS) |i| {
            const name = comptime std.fmt.comptimePrint("equip_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_equip_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
        }
        self.inv_offhand_id = tree.findById("inv_offhand") orelse NULL_WIDGET;
        self.makeSlotClickable(tree, self.inv_offhand_id, hover_col);
        self.inv_player_viewport_id = tree.findById("player_viewport") orelse NULL_WIDGET;
        if (self.inv_player_viewport_id != NULL_WIDGET) {
            if (tree.getData(self.inv_player_viewport_id)) |data| {
                data.panel.setAction("player_viewport_drag");
            }
        }
        self.cursor_item_id = tree.findById("cursor_item") orelse NULL_WIDGET;
        if (self.cursor_item_id != NULL_WIDGET) {
            if (tree.getWidget(self.cursor_item_id)) |w| {
                w.hit_transparent = true;
            }
            if (tree.getData(self.cursor_item_id)) |data| {
                data.panel.draw_isometric = true;
            }
            self.ui_manager.cursor_follow_widget = self.cursor_item_id;
        }

        // Resolve inventory sprite UVs to image widgets
        if (self.ui_renderer) |ur| {
            if (ur.hud_atlas_loaded) {
                setImageAtlas(tree, tree.findById("inv_bg") orelse NULL_WIDGET, ur.inv_bg_rect);
                setImageAtlas(tree, tree.findById("inv_player_bg") orelse NULL_WIDGET, ur.inv_player_rect);
            }
        }
    }

    fn setImageAtlas(tree: *WidgetTree, id: WidgetId, rect: @import("../renderer/vulkan/UiRenderer.zig").SpriteRect) void {
        if (id == NULL_WIDGET) return;
        const data = tree.getData(id) orelse return;
        data.image.atlas_u = rect.u0;
        data.image.atlas_v = rect.v0;
        data.image.atlas_w = rect.u1 - rect.u0;
        data.image.atlas_h = rect.v1 - rect.v0;
    }

    fn makeSlotClickable(_: *MenuController, tree: *WidgetTree, id: WidgetId, hover_col: Widget.Color) void {
        if (id == NULL_WIDGET) return;
        if (tree.getData(id)) |data| {
            data.panel.setAction("inv_slot_click");
            data.panel.hover_color = hover_col;
            data.panel.draw_isometric = true;
        }
    }

    fn resetInventoryWidgetIds(self: *MenuController) void {
        self.inv_slot_ids = .{NULL_WIDGET} ** GameState.HOTBAR_SIZE;
        self.inv_main_ids = .{NULL_WIDGET} ** GameState.INV_SIZE;
        self.inv_armor_ids = .{NULL_WIDGET} ** GameState.ARMOR_SLOTS;
        self.inv_equip_ids = .{NULL_WIDGET} ** GameState.EQUIP_SLOTS;
        self.inv_offhand_id = NULL_WIDGET;
        self.inv_player_viewport_id = NULL_WIDGET;
        self.cursor_item_id = NULL_WIDGET;
        self.ui_manager.cursor_follow_widget = NULL_WIDGET;
        self.entity_visible = false;
        self.entity_viewport = .{ 0, 0, 0, 0 };
    }

    // ============================================================
    // Actions registration
    // ============================================================

    pub fn registerActions(self: *MenuController) void {
        const reg = &self.ui_manager.registry;
        const ctx: *anyopaque = @ptrCast(self);
        reg.register("play_world", actionPlayWorld, ctx);
        reg.register("show_create_world", actionShowCreateWorld, ctx);
        reg.register("confirm_create_world", actionConfirmCreateWorld, ctx);
        reg.register("toggle_world_type", actionToggleWorldType, ctx);
        reg.register("cancel_create_world", actionCancelCreateWorld, ctx);
        reg.register("delete_world", actionDeleteWorld, ctx);
        reg.register("confirm_delete", actionConfirmDelete, ctx);
        reg.register("cancel_delete", actionCancelDelete, ctx);
        reg.register("resume_game", actionResumeGame, ctx);
        reg.register("return_to_title", actionReturnToTitle, ctx);
        reg.register("quit_game", actionQuitGame, ctx);
        reg.register("world_select", actionWorldSelect, ctx);
        reg.register("show_singleplayer", actionShowSingleplayer, ctx);
        reg.register("search_worlds", actionSearchWorlds, ctx);
        reg.register("back_to_title", actionBackToTitle, ctx);
        reg.register("show_coming_soon", actionShowComingSoon, ctx);
        reg.register("dismiss_modal", actionDismissModal, ctx);
        reg.register("show_controls", actionShowControls, ctx);
        reg.register("show_controls_pause", actionShowControlsPause, ctx);
        reg.register("close_controls", actionCloseControls, ctx);
        reg.register("reset_keybinds", actionResetKeybinds, ctx);
        reg.register("rebind_key", actionRebindKey, ctx);
        reg.register("toggle_tp_crosshair", actionToggleTpCrosshair, ctx);
        reg.register("toggle_tp_crosshair_cb", actionToggleTpCrosshairCb, ctx);
        reg.register("inv_slot_click", actionInvSlotClick, ctx);
    }

    // ============================================================
    // World list
    // ============================================================

    pub fn refreshWorldList(self: *MenuController) void {
        self.world_count = 0;
        self.selection = 0;

        var name_slices: [MAX_WORLDS][]const u8 = undefined;
        const count = app_config.listWorlds(self.allocator, &name_slices) catch 0;

        for (0..count) |i| {
            const name = name_slices[i];
            const len: u8 = @intCast(@min(name.len, MAX_NAME_LEN));
            @memcpy(self.world_names[i][0..len], name[0..len]);
            self.world_name_lens[i] = len;
            self.allocator.free(name);
        }
        self.world_count = count;

        self.populateWorldListWidget();
    }

    fn getSearchFilter(self: *MenuController) []const u8 {
        if (self.world_search_input_id == NULL_WIDGET) return "";
        const tree = self.menuTree() orelse return "";
        const data = tree.getDataConst(self.world_search_input_id) orelse return "";
        return data.text_input.getText();
    }

    fn matchesSearch(name: []const u8, filter: []const u8) bool {
        if (filter.len == 0) return true;
        if (filter.len > name.len) return false;
        for (0..name.len - filter.len + 1) |start| {
            var match = true;
            for (0..filter.len) |j| {
                if (std.ascii.toLower(name[start + j]) != std.ascii.toLower(filter[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn populateWorldListWidget(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        const filter = self.getSearchFilter();

        var visible_count: u8 = 0;

        if (self.world_list_id != NULL_WIDGET) {
            tree.clearChildren(self.world_list_id);
            for (0..self.world_count) |i| {
                const name = self.world_names[i][0..self.world_name_lens[i]];
                if (!matchesSearch(name, filter)) continue;
                visible_count += 1;

                const row_id = tree.addWidget(.panel, self.world_list_id) orelse break;
                if (tree.getWidget(row_id)) |w| {
                    w.width = .fill;
                    w.height = .{ .px = 72 };
                    w.flex_direction = .row;
                    w.gap = 8;
                    w.cross_align = .center;
                    w.padding = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 };
                }

                const img_id = tree.addWidget(.panel, row_id) orelse break;
                if (tree.getWidget(img_id)) |w| {
                    w.width = .{ .px = 56 };
                    w.height = .{ .px = 56 };
                    w.background = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
                }

                const col_id = tree.addWidget(.panel, row_id) orelse break;
                if (tree.getWidget(col_id)) |w| {
                    w.width = .fill;
                    w.height = .auto;
                    w.flex_direction = .column;
                    w.gap = 2;
                }

                const title_id = tree.addWidget(.label, col_id) orelse break;
                if (tree.getWidget(title_id)) |w| {
                    w.width = .fill;
                    w.height = .auto;
                }
                if (tree.getData(title_id)) |data| {
                    data.label.setText(name);
                    data.label.color = Widget.Color.white;
                }

                const date_id = tree.addWidget(.label, col_id) orelse break;
                if (tree.getWidget(date_id)) |w| {
                    w.width = .fill;
                    w.height = .auto;
                }
                if (tree.getData(date_id)) |data| {
                    data.label.setText("Last played: Unknown");
                    data.label.color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
                }

                const ver_id = tree.addWidget(.label, col_id) orelse break;
                if (tree.getWidget(ver_id)) |w| {
                    w.width = .fill;
                    w.height = .auto;
                }
                if (tree.getData(ver_id)) |data| {
                    data.label.setText("Version: Alpha 0.1.0");
                    data.label.color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
                }
            }

            if (tree.getData(self.world_list_id)) |data| {
                data.list_view.item_count = visible_count;
                data.list_view.selected_index = 0;
                data.list_view.scroll_offset = 0;
                data.list_view.scroll_target = 0;
            }
        }

        if (self.no_worlds_label_id != NULL_WIDGET) {
            if (tree.getWidget(self.no_worlds_label_id)) |w| {
                w.visible = (visible_count == 0);
            }
        }

        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    // ============================================================
    // Public API for main.zig
    // ============================================================

    pub fn showPauseMenu(self: *MenuController) void {
        self.loadScreen(.pause);
        self.app_state = .pause_menu;
    }

    pub fn hidePauseMenu(self: *MenuController) void {
        self.unloadScreen(.pause);
        self.app_state = .playing;
    }

    pub fn showInventory(self: *MenuController) void {
        self.loadScreen(.inventory);
        self.app_state = .inventory;
    }

    pub fn hideInventory(self: *MenuController, gs: ?*GameState) void {
        // Return carried item to inventory when closing
        if (gs) |g| {
            if (g.carried_item != BlockState.defaultState(.air)) {
                // Find first empty slot to place carried item
                for (&g.hotbar) |*slot| {
                    if (slot.* == BlockState.defaultState(.air)) {
                        slot.* = g.carried_item;
                        g.carried_item = BlockState.defaultState(.air);
                        break;
                    }
                }
                if (g.carried_item != BlockState.defaultState(.air)) {
                    for (&g.inventory) |*slot| {
                        if (slot.* == BlockState.defaultState(.air)) {
                            slot.* = g.carried_item;
                            g.carried_item = BlockState.defaultState(.air);
                            break;
                        }
                    }
                }
                // If still not placed, just drop it (clear it)
                g.carried_item = BlockState.defaultState(.air);
            }
        }
        self.game_state = null;
        self.unloadScreen(.inventory);
        self.app_state = .playing;
    }

    pub fn updateInventory(self: *MenuController, gs: *GameState) void {
        if (self.app_state != .inventory) {
            self.entity_visible = false;
            self.game_state = null;
            return;
        }
        self.game_state = gs;
        const tree = self.menuTree() orelse return;

        // Update entity renderer viewport from player_viewport widget rect
        if (self.inv_player_viewport_id != NULL_WIDGET) {
            if (tree.getWidget(self.inv_player_viewport_id)) |w| {
                self.entity_viewport = .{ w.computed_rect.x, w.computed_rect.y, w.computed_rect.w, w.computed_rect.h };
                self.entity_visible = true;
            }
        }

        // Update hotbar row
        for (0..GameState.HOTBAR_SIZE) |i| {
            const id = self.inv_slot_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, gs.hotbar[i]);
                }
            }
        }

        // Update main inventory
        for (0..GameState.INV_SIZE) |i| {
            const id = self.inv_main_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, gs.inventory[i]);
                }
            }
        }

        // Update armor slots
        for (0..GameState.ARMOR_SLOTS) |i| {
            const id = self.inv_armor_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, gs.armor[i]);
                }
            }
        }

        // Update equip slots
        for (0..GameState.EQUIP_SLOTS) |i| {
            const id = self.inv_equip_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, gs.equip[i]);
                }
            }
        }

        // Update offhand
        if (self.inv_offhand_id != NULL_WIDGET) {
            const id = self.inv_offhand_id;
            if (tree.getWidget(id)) |w| {
                updateSlotWidget(w, tree, id, gs.offhand);
            }
        }

        // Update cursor item (follows mouse when carrying)
        if (self.cursor_item_id != NULL_WIDGET) {
            const cid = self.cursor_item_id;
            if (tree.getWidget(cid)) |w| {
                if (gs.carried_item != BlockState.defaultState(.air)) {
                    const c = GameState.blockColor(gs.carried_item);
                    w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                    const tex = GameState.blockTexIndices(gs.carried_item);
                    if (tree.getData(cid)) |data| {
                        data.panel.block_tex_top = tex.top;
                        data.panel.block_tex_side = tex.side;
                        data.panel.block_shape = GameState.blockShape(gs.carried_item);
                    }
                    w.visible = true;
                } else {
                    w.visible = false;
                }
            }
        }

        // Player model drag-to-rotate
        const mouse_x = self.ui_manager.last_mouse_x;
        if (self.ui_manager.pressed_widget != NULL_WIDGET and
            self.inv_player_viewport_id != NULL_WIDGET and
            self.ui_manager.pressed_widget == self.inv_player_viewport_id)
        {
            if (!self.dragging_player) {
                self.dragging_player = true;
                self.drag_start_x = mouse_x;
            } else {
                const dx = mouse_x - self.drag_start_x;
                self.player_rotation -= dx * 0.01;
                self.drag_start_x = mouse_x;
            }
        } else {
            self.dragging_player = false;
        }
    }

    pub fn showTitleMenu(self: *MenuController) void {
        // Unload any gameplay screens (pause, inventory, hud)
        if (self.app_state == .pause_menu) {
            self.unloadScreen(.pause);
        }
        if (self.app_state == .inventory) {
            // Return carried item before closing
            if (self.game_state) |gs| {
                gs.carried_item = BlockState.defaultState(.air);
            }
            self.game_state = null;
            self.unloadScreen(.inventory);
        }
        if (self.hud_binder != null) {
            self.unloadHud();
        }
        self.loadScreen(.title);
        self.app_state = .title_menu;
    }

    pub fn hideTitleMenu(self: *MenuController) void {
        // Unload whatever menu screen is on top
        if (screenTypeFor(self.app_state)) |st| {
            self.unloadScreen(st);
        }
    }

    fn hudTree(self: *MenuController) ?*WidgetTree {
        if (self.hud_binder == null) return null;
        if (self.ui_manager.screen_count == 0) return null;
        if (!self.ui_manager.screens[0].active) return null;
        return &self.ui_manager.screens[0].tree;
    }

    pub fn loadHud(self: *MenuController, ui_renderer: *const UiRenderer) void {
        self.ui_renderer = ui_renderer;
        if (self.hud_binder != null) return;
        if (self.ui_manager.loadScreenFromFile("hud.xml", self.allocator)) {
            // Access screens[0] directly — hudTree() can't be used yet because hud_binder is still null
            if (self.ui_manager.screen_count == 0 or !self.ui_manager.screens[0].active) return;
            const tree = &self.ui_manager.screens[0].tree;
            var binder = HudBinder.init(tree);
            binder.resolveSprites(tree, ui_renderer);
            self.hud_binder = binder;
        } else {
            log.err("Failed to load hud.xml", .{});
        }
    }

    pub fn unloadHud(self: *MenuController) void {
        if (self.hud_binder == null) return;
        // If pause screen is on top of hud, remove it first
        if (self.app_state == .pause_menu) {
            self.unloadScreen(.pause);
        }
        if (self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
        }
        self.hud_binder = null;
    }

    pub fn updateHud(self: *MenuController, gs: *const GameState) void {
        const binder = self.hud_binder orelse return;
        const tree = self.hudTree() orelse return;
        if (tree.getWidget(tree.root)) |root| {
            root.visible = gs.show_ui;
        }
        binder.update(tree, gs);
    }

    pub fn getSelectedWorldName(self: *const MenuController) []const u8 {
        if (self.world_count == 0) return "";
        const sel = self.selection;
        if (sel >= self.world_count) return "";
        return self.world_names[sel][0..self.world_name_lens[sel]];
    }

    pub fn getInputName(self: *const MenuController) []const u8 {
        if (self.app_state != .create_world) return "";
        if (self.ui_manager.screen_count == 0) return "";
        const tree = &self.ui_manager.screens[self.ui_manager.screen_count - 1].tree;
        if (self.create_world_input_id == NULL_WIDGET) return "";
        const data = tree.getDataConst(self.create_world_input_id) orelse return "";
        return data.text_input.getText();
    }

    // ============================================================
    // Controls screen
    // ============================================================

    fn populateKeybindList(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        const opts = self.options orelse return;
        if (self.keybind_list_id == NULL_WIDGET) return;

        tree.clearChildren(self.keybind_list_id);

        inline for (@typeInfo(Options.Action).@"enum".fields) |field| {
            const act: Options.Action = @enumFromInt(field.value);
            const display = act.displayName();
            const binding = opts.bindings[field.value];
            const key_display = Options.inputDisplayName(binding);

            const row_id = tree.addWidget(.panel, self.keybind_list_id) orelse return;
            if (tree.getWidget(row_id)) |w| {
                w.width = .fill;
                w.height = .{ .px = 28 };
                w.flex_direction = .row;
                w.cross_align = .center;
                w.padding = .{ .top = 2, .right = 8, .bottom = 2, .left = 8 };
                w.background = .{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 0.5 };
            }

            const label_id = tree.addWidget(.label, row_id) orelse return;
            if (tree.getWidget(label_id)) |w| {
                w.width = .fill;
                w.height = .auto;
                w.flex_grow = 1.0;
            }
            if (tree.getData(label_id)) |data| {
                data.label.setText(display);
                data.label.color = .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 };
            }

            const btn_id = tree.addWidget(.button, row_id) orelse return;
            if (tree.getWidget(btn_id)) |w| {
                w.width = .{ .px = 140 };
                w.height = .{ .px = 24 };
                w.background = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
            }
            if (tree.getData(btn_id)) |data| {
                data.button.setText(key_display);
                data.button.setAction("rebind_key");
                data.button.text_color = .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 };
                data.button.hover_color = .{ .r = 0.3, .g = 0.3, .b = 0.45, .a = 1.0 };
                data.button.press_color = .{ .r = 0.15, .g = 0.15, .b = 0.25, .a = 1.0 };
            }

            self.keybind_button_ids[field.value] = btn_id;
        }
    }

    fn updateKeybindButton(self: *MenuController, act: Options.Action) void {
        const tree = self.menuTree() orelse return;
        const opts = self.options orelse return;
        const idx = @intFromEnum(act);
        const btn_id = self.keybind_button_ids[idx];
        if (btn_id == NULL_WIDGET) return;
        if (tree.getData(btn_id)) |data| {
            data.button.setText(Options.inputDisplayName(opts.bindings[idx]));
            data.button.text_color = .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 };
        }
        if (tree.getWidget(btn_id)) |w| {
            w.background = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
        }
    }

    fn setRebindingVisual(self: *MenuController, act: Options.Action) void {
        const tree = self.menuTree() orelse return;
        const idx = @intFromEnum(act);
        const btn_id = self.keybind_button_ids[idx];
        if (btn_id == NULL_WIDGET) return;
        if (tree.getData(btn_id)) |data| {
            data.button.setText("> ... <");
            data.button.text_color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
        }
        if (tree.getWidget(btn_id)) |w| {
            w.background = .{ .r = 0.4, .g = 0.2, .b = 0.2, .a = 1.0 };
        }
        if (self.rebind_hint_id != NULL_WIDGET) {
            if (tree.getData(self.rebind_hint_id)) |data| {
                data.label.setText("Press a key or mouse button...");
                data.label.color = .{ .r = 1.0, .g = 1.0, .b = 0.4, .a = 1.0 };
            }
        }
    }

    fn clearRebindHint(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        if (self.rebind_hint_id != NULL_WIDGET) {
            if (tree.getData(self.rebind_hint_id)) |data| {
                data.label.setText("Click a key to rebind");
                data.label.color = .{ .r = 0.53, .g = 0.53, .b = 0.53, .a = 1.0 };
            }
        }
    }

    pub fn handleRebindKey(self: *MenuController, code: Options.InputCode) void {
        const act = self.rebinding_action orelse return;
        const opts = self.options orelse return;

        opts.bindings[@intFromEnum(act)] = code;
        self.updateKeybindButton(act);
        self.rebinding_action = null;
        self.clearRebindHint();
        opts.save(self.allocator);
    }

    pub fn cancelRebind(self: *MenuController) void {
        if (self.rebinding_action) |act| {
            self.updateKeybindButton(act);
            self.rebinding_action = null;
            self.clearRebindHint();
        }
    }

    // ============================================================
    // Delete confirm (modal within singleplayer screen)
    // ============================================================

    pub fn showDeleteConfirm(self: *MenuController) void {
        if (self.world_count == 0) return;
        const tree = self.menuTree() orelse return;
        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = true;
            }
        }
        if (self.delete_label_id != NULL_WIDGET) {
            if (tree.getData(self.delete_label_id)) |data| {
                const world_name = self.getSelectedWorldName();
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Delete \"{s}\"?", .{world_name}) catch "Delete?";
                data.label.setText(text);
            }
        }
    }

    // ============================================================
    // Action handlers (called from UI button clicks)
    // ============================================================

    fn actionPlayWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.world_count > 0) {
            self.action = .load_world;
        }
    }

    fn actionShowCreateWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.create_world);
    }

    fn actionConfirmCreateWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const name = self.getInputName();
        if (name.len > 0) {
            self.action = .create_world;
        }
    }

    fn actionToggleWorldType(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.selected_world_type = switch (self.selected_world_type) {
            .normal => .debug,
            .debug => .normal,
        };
        self.updateWorldTypeLabel();
    }

    fn updateWorldTypeLabel(self: *MenuController) void {
        if (self.world_type_label_id == NULL_WIDGET) return;
        const tree = self.menuTree() orelse return;
        if (tree.getData(self.world_type_label_id)) |data| {
            data.label.setText(switch (self.selected_world_type) {
                .normal => "World Type: Normal",
                .debug => "World Type: Debug",
            });
        }
    }

    fn actionCancelCreateWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.singleplayer_menu);
    }

    fn actionDeleteWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).showDeleteConfirm();
    }

    fn actionConfirmDelete(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.action = .delete_world;
        const tree = self.menuTree() orelse return;
        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionCancelDelete(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.menuTree() orelse return;
        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionResumeGame(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.hidePauseMenu();
        self.action = .resume_game;
    }

    fn actionReturnToTitle(ctx: ?*anyopaque) void {
        getSelf(ctx).action = .return_to_title;
    }

    fn actionQuitGame(ctx: ?*anyopaque) void {
        getSelf(ctx).action = .quit;
    }

    fn actionWorldSelect(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.menuTree() orelse return;
        if (self.world_list_id != NULL_WIDGET) {
            if (tree.getDataConst(self.world_list_id)) |data| {
                const idx = data.list_view.selected_index;
                if (idx < self.world_count) {
                    self.selection = @intCast(idx);
                }
            }
        }
    }

    fn actionSearchWorlds(ctx: ?*anyopaque) void {
        getSelf(ctx).populateWorldListWidget();
    }

    fn actionShowSingleplayer(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.singleplayer_menu);
    }

    fn actionBackToTitle(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.title_menu);
    }

    fn actionShowComingSoon(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.menuTree() orelse return;
        if (self.coming_soon_modal_id != NULL_WIDGET) {
            if (tree.getWidget(self.coming_soon_modal_id)) |w| {
                w.visible = true;
            }
        }
    }

    fn actionDismissModal(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.menuTree() orelse return;
        if (self.coming_soon_modal_id != NULL_WIDGET) {
            if (tree.getWidget(self.coming_soon_modal_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionShowControls(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.controls_title);
    }

    fn actionShowControlsPause(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.controls_pause);
    }

    fn actionCloseControls(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.cancelRebind();
        const target: AppState = if (self.app_state == .controls_pause) .pause_menu else .title_menu;
        self.transitionTo(target);
    }

    /// Called when the panel group is clicked (label or gap) — manually toggle the checkbox
    fn actionToggleTpCrosshair(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const opts = self.options orelse return;
        const tree = self.menuTree() orelse return;
        if (self.tp_crosshair_cb_id != NULL_WIDGET) {
            if (tree.getData(self.tp_crosshair_cb_id)) |data| {
                data.checkbox.checked = !data.checkbox.checked;
                opts.third_person_crosshair = data.checkbox.checked;
            }
        }
        opts.save(self.allocator);
    }

    /// Called when the checkbox itself is clicked (EventDispatch already toggled .checked)
    fn actionToggleTpCrosshairCb(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const opts = self.options orelse return;
        const tree = self.menuTree() orelse return;
        if (self.tp_crosshair_cb_id != NULL_WIDGET) {
            if (tree.getData(self.tp_crosshair_cb_id)) |data| {
                opts.third_person_crosshair = data.checkbox.checked;
            }
        }
        opts.save(self.allocator);
    }

    fn actionInvSlotClick(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const pressed = self.ui_manager.pressed_widget;
        if (pressed == NULL_WIDGET) return;

        // Resolve which unified slot index was clicked
        const slot: ?u8 = blk: {
            for (self.inv_slot_ids, 0..) |id, i| {
                if (id == pressed) break :blk @intCast(i); // hotbar: 0-8
            }
            for (self.inv_main_ids, 0..) |id, i| {
                if (id == pressed) break :blk @as(u8, GameState.HOTBAR_SIZE) + @as(u8, @intCast(i)); // main: 9-35
            }
            for (self.inv_armor_ids, 0..) |id, i| {
                if (id == pressed) break :blk @as(u8, GameState.HOTBAR_SIZE + GameState.INV_SIZE) + @as(u8, @intCast(i)); // armor: 36-39
            }
            for (self.inv_equip_ids, 0..) |id, i| {
                if (id == pressed) break :blk @as(u8, GameState.HOTBAR_SIZE + GameState.INV_SIZE + GameState.ARMOR_SLOTS) + @as(u8, @intCast(i)); // equip: 40-43
            }
            if (self.inv_offhand_id == pressed) break :blk GameState.HOTBAR_SIZE + GameState.INV_SIZE + GameState.ARMOR_SLOTS + GameState.EQUIP_SLOTS; // offhand: 44
            break :blk null;
        };

        if (slot) |s| {
            if (self.game_state) |gs| {
                const shift = (self.ui_manager.last_mods & glfw.GLFW_MOD_SHIFT) != 0;
                if (shift) {
                    gs.quickMove(s);
                } else {
                    gs.clickSlot(s);
                }
            }
        }
    }

    fn actionResetKeybinds(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const opts = self.options orelse return;
        opts.bindings = Options.defaults;
        self.rebinding_action = null;
        self.populateKeybindList();
        self.clearRebindHint();
        opts.save(self.allocator);
    }

    fn actionRebindKey(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const pressed = self.ui_manager.pressed_widget;
        if (pressed == NULL_WIDGET) return;

        if (self.rebinding_action) |prev| {
            self.updateKeybindButton(prev);
        }

        for (&self.keybind_button_ids, 0..) |btn_id, i| {
            if (btn_id == pressed) {
                const act: Options.Action = @enumFromInt(i);
                self.rebinding_action = act;
                self.setRebindingVisual(act);
                return;
            }
        }
    }

    const WorldState = @import("../world/WorldState.zig");

    fn updateSlotWidget(w: *Widget.Widget, tree: *WidgetTree, id: WidgetId, block: BlockState.StateId) void {
        if (BlockState.getBlock(block) != .air) {
            const c = GameState.blockColor(block);
            w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
            const tex = GameState.blockTexIndices(block);
            if (tree.getData(id)) |data| {
                data.panel.block_tex_top = tex.top;
                data.panel.block_tex_side = tex.side;
                data.panel.block_shape = GameState.blockShape(block);
            }
            const name = GameState.blockName(block);
            const len: u8 = @intCast(@min(name.len, 64));
            @memcpy(w.tooltip[0..len], name[0..len]);
            w.tooltip_len = len;
        } else {
            w.background = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            if (tree.getData(id)) |data| {
                data.panel.block_tex_top = -1;
                data.panel.block_tex_side = -1;
                data.panel.block_shape = .full;
            }
            w.tooltip_len = 0;
        }
    }

    fn getSelf(ctx: ?*anyopaque) *MenuController {
        return @ptrCast(@alignCast(ctx.?));
    }
};
