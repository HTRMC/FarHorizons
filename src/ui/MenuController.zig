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
const Gamepad = @import("../Gamepad.zig");

const Crafting = @import("../Crafting.zig");
const log = std.log.scoped(.UI);

pub const MAX_WORLDS: u8 = 32;
pub const MAX_NAME_LEN: u8 = 32;
pub const MAX_DISPLAY_LEN: u8 = 32;

pub const AppState = enum {
    title_menu,
    singleplayer_menu,
    create_world,
    edit_world,
    controls_title,
    controls_pause,
    loading,
    playing,
    pause_menu,
    inventory,
    crafting,
    saving,

    pub fn isMenu(self: AppState) bool {
        return switch (self) {
            .title_menu, .singleplayer_menu, .create_world, .edit_world, .controls_title, .controls_pause, .pause_menu, .inventory, .crafting => true,
            .loading, .playing, .saving => false,
        };
    }
};

pub const Action = enum { load_world, create_world, delete_world, backup_world, edit_world, resume_game, return_to_title, quit };

const ScreenType = enum {
    title,
    singleplayer,
    create_world,
    edit_world,
    controls,
    pause,
    inventory,
    crafting,
};

pub const MenuController = struct {
    pub const CraftingMode = enum { hand, workbench };
    pub const MAX_RECIPES: u8 = 64;

    ui_manager: *UiManager,
    allocator: std.mem.Allocator,
    app_state: AppState = .title_menu,
    action: ?Action = null,

    world_names: [MAX_WORLDS][MAX_NAME_LEN]u8 = undefined,
    world_name_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
    world_display_names: [MAX_WORLDS][MAX_DISPLAY_LEN]u8 = undefined,
    world_display_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
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
    fov_slider_id: WidgetId = NULL_WIDGET,
    fov_label_id: WidgetId = NULL_WIDGET,

    // Game state reference (set during updateInventory for action handlers)
    game_state: ?*GameState = null,

    // Inventory screen state
    inv_slot_ids: [GameState.HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.HOTBAR_SIZE, // hotbar row
    inv_main_ids: [GameState.INV_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.INV_SIZE, // 3x9 main
    inv_armor_ids: [GameState.ARMOR_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.ARMOR_SLOTS,
    inv_equip_ids: [GameState.EQUIP_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.EQUIP_SLOTS,
    inv_offhand_id: WidgetId = NULL_WIDGET,
    inv_slot_count_ids: [GameState.HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.HOTBAR_SIZE,
    inv_main_count_ids: [GameState.INV_SIZE]WidgetId = .{NULL_WIDGET} ** GameState.INV_SIZE,
    inv_armor_count_ids: [GameState.ARMOR_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.ARMOR_SLOTS,
    inv_equip_count_ids: [GameState.EQUIP_SLOTS]WidgetId = .{NULL_WIDGET} ** GameState.EQUIP_SLOTS,
    inv_offhand_count_id: WidgetId = NULL_WIDGET,
    cursor_count_id: WidgetId = NULL_WIDGET,
    inv_player_viewport_id: WidgetId = NULL_WIDGET,
    cursor_item_id: WidgetId = NULL_WIDGET,
    // Entity renderer viewport (in UI coords), read by VulkanRenderer
    entity_viewport: [4]f32 = .{ 0, 0, 0, 0 },
    entity_visible: bool = false,
    player_rotation: f32 = 0.4,
    dragging_player: bool = false,
    drag_start_x: f32 = 0,

    // Crafting screen state
    crafting_mode: CraftingMode = .hand,
    selected_recipe: ?u8 = null,
    crafting_title_id: WidgetId = NULL_WIDGET,
    recipe_list_id: WidgetId = NULL_WIDGET,
    detail_icon_id: WidgetId = NULL_WIDGET,
    detail_name_id: WidgetId = NULL_WIDGET,
    material_list_id: WidgetId = NULL_WIDGET,
    craft_btn_id: WidgetId = NULL_WIDGET,
    recipe_row_ids: [MAX_RECIPES]WidgetId = .{NULL_WIDGET} ** MAX_RECIPES,
    recipe_indices: [MAX_RECIPES]u8 = .{0} ** MAX_RECIPES,
    visible_recipe_count: u8 = 0,
    crafting_details_dirty: bool = true,

    coming_soon_modal_id: WidgetId = NULL_WIDGET,

    world_list_id: WidgetId = NULL_WIDGET,
    no_worlds_label_id: WidgetId = NULL_WIDGET,
    delete_confirm_id: WidgetId = NULL_WIDGET,
    delete_label_id: WidgetId = NULL_WIDGET,
    backup_confirm_id: WidgetId = NULL_WIDGET,
    backup_label_id: WidgetId = NULL_WIDGET,
    world_search_input_id: WidgetId = NULL_WIDGET,
    create_world_input_id: WidgetId = NULL_WIDGET,
    seed_input_id: WidgetId = NULL_WIDGET,
    world_type_label_id: WidgetId = NULL_WIDGET,
    selected_world_type: @import("../world/WorldState.zig").WorldType = .normal,
    game_mode_label_id: WidgetId = NULL_WIDGET,
    selected_game_mode: @import("../GameState.zig").GameMode = .creative,

    // Edit world screen state
    edit_world_name_input_id: WidgetId = NULL_WIDGET,
    edit_game_mode_label_id: WidgetId = NULL_WIDGET,
    edit_game_mode: @import("../GameState.zig").GameMode = .creative,
    edit_world_name: [MAX_NAME_LEN]u8 = undefined,
    edit_world_name_len: u8 = 0,

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
            .edit_world => .edit_world,
            .controls_title, .controls_pause => .controls,
            .pause_menu => .pause,
            .inventory => .inventory,
            .crafting => .crafting,
            .loading, .playing, .saving => null,
        };
    }

    fn loadScreen(self: *MenuController, screen: ScreenType) void {
        const file = switch (screen) {
            .title => "title_menu.xml",
            .singleplayer => "singleplayer_menu.xml",
            .create_world => "create_world_menu.xml",
            .edit_world => "edit_world_menu.xml",
            .controls => "controls_menu.xml",
            .pause => "pause_menu.xml",
            .inventory => "inventory.xml",
            .crafting => "crafting.xml",
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
                    self.selected_game_mode = .creative;
                },
                .edit_world => {
                    self.cacheEditWorldWidgetIds();
                    self.populateEditWorldScreen();
                },
                .controls => {
                    self.cacheControlsWidgetIds();
                    self.populateKeybindList();
                },
                .pause => {},
                .inventory => self.cacheInventoryWidgetIds(),
                .crafting => self.cacheCraftingWidgetIds(),
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
                self.seed_input_id = NULL_WIDGET;
                self.world_type_label_id = NULL_WIDGET;
                self.game_mode_label_id = NULL_WIDGET;
            },
            .edit_world => {
                self.edit_world_name_input_id = NULL_WIDGET;
                self.edit_game_mode_label_id = NULL_WIDGET;
            },
            .controls => self.resetControlsWidgetIds(),
            .pause => {},
            .inventory => self.resetInventoryWidgetIds(),
            .crafting => self.resetCraftingWidgetIds(),
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
        self.backup_confirm_id = tree.findById("backup_confirm") orelse NULL_WIDGET;
        self.backup_label_id = tree.findById("backup_label") orelse NULL_WIDGET;
        self.world_search_input_id = tree.findById("world_search_input") orelse NULL_WIDGET;
    }

    fn cacheCreateWorldWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.create_world_input_id = tree.findById("create_world_input") orelse NULL_WIDGET;
        self.seed_input_id = tree.findById("create_seed_input") orelse NULL_WIDGET;
        self.world_type_label_id = tree.findById("world_type_label") orelse NULL_WIDGET;
        self.game_mode_label_id = tree.findById("game_mode_label") orelse NULL_WIDGET;
    }

    fn cacheEditWorldWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.edit_world_name_input_id = tree.findById("edit_world_name_input") orelse NULL_WIDGET;
        self.edit_game_mode_label_id = tree.findById("edit_game_mode_label") orelse NULL_WIDGET;
    }

    fn populateEditWorldScreen(self: *MenuController) void {
        const folder = self.edit_world_name[0..self.edit_world_name_len];

        // Load current values from disk
        self.edit_game_mode = if (app_config.hasWorldGameMode(self.allocator, folder))
            app_config.loadWorldGameMode(self.allocator, folder)
        else
            .creative;

        // Get display name for pre-filling
        const display = if (app_config.loadDisplayName(self.allocator, folder)) |d| d else null;
        defer if (display) |d| self.allocator.free(d);
        const fill_name = if (display) |d| d else folder;

        // Set world name input
        const tree = self.menuTree() orelse return;
        if (self.edit_world_name_input_id != NULL_WIDGET) {
            if (tree.getData(self.edit_world_name_input_id)) |data| {
                const len = @min(fill_name.len, data.text_input.max_len);
                @memcpy(data.text_input.buffer[0..len], fill_name[0..len]);
                data.text_input.buffer_len = @intCast(len);
                data.text_input.cursor_pos = @intCast(len);
                data.text_input.selection_start = @intCast(len);
            }
        }
        self.updateEditGameModeLabel();
    }

    fn updateEditGameModeLabel(self: *MenuController) void {
        if (self.edit_game_mode_label_id == NULL_WIDGET) return;
        const tree = self.menuTree() orelse return;
        if (tree.getData(self.edit_game_mode_label_id)) |data| {
            data.label.setText(switch (self.edit_game_mode) {
                .creative => "Game Mode: Creative",
                .survival => "Game Mode: Survival",
            });
        }
    }

    fn cacheControlsWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.keybind_list_id = tree.findById("keybind_list") orelse NULL_WIDGET;
        self.rebind_hint_id = tree.findById("rebind_hint") orelse NULL_WIDGET;
        self.tp_crosshair_cb_id = tree.findById("tp_crosshair_cb") orelse NULL_WIDGET;
        self.fov_slider_id = tree.findById("fov_slider") orelse NULL_WIDGET;
        self.fov_label_id = tree.findById("fov_label") orelse NULL_WIDGET;

        // Sync checkbox state from options
        if (self.options) |opts| {
            if (self.tp_crosshair_cb_id != NULL_WIDGET) {
                if (tree.getData(self.tp_crosshair_cb_id)) |data| {
                    data.checkbox.checked = opts.third_person_crosshair;
                }
            }
            // Sync FOV slider from options
            if (self.fov_slider_id != NULL_WIDGET) {
                if (tree.getData(self.fov_slider_id)) |data| {
                    data.slider.value = opts.fov;
                }
            }
            self.updateFovLabel();
        }
    }

    fn resetSingleplayerWidgetIds(self: *MenuController) void {
        self.world_list_id = NULL_WIDGET;
        self.no_worlds_label_id = NULL_WIDGET;
        self.delete_confirm_id = NULL_WIDGET;
        self.delete_label_id = NULL_WIDGET;
        self.backup_confirm_id = NULL_WIDGET;
        self.backup_label_id = NULL_WIDGET;
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
        @setEvalBranchQuota(32000);
        const tree = self.menuTree() orelse return;
        const hover_col = Widget.Color.fromHex(0xFFFFFF22);
        inline for (0..GameState.HOTBAR_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("hotbar_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_slot_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
            const cname = comptime std.fmt.comptimePrint("hotbar_count_{d}", .{i});
            self.inv_slot_count_ids[i] = tree.findById(cname) orelse NULL_WIDGET;
        }
        inline for (0..GameState.INV_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("inv_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_main_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
            const cname = comptime std.fmt.comptimePrint("inv_count_{d}", .{i});
            self.inv_main_count_ids[i] = tree.findById(cname) orelse NULL_WIDGET;
        }
        inline for (0..GameState.ARMOR_SLOTS) |i| {
            const name = comptime std.fmt.comptimePrint("armor_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_armor_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
            const cname = comptime std.fmt.comptimePrint("armor_count_{d}", .{i});
            self.inv_armor_count_ids[i] = tree.findById(cname) orelse NULL_WIDGET;
        }
        inline for (0..GameState.EQUIP_SLOTS) |i| {
            const name = comptime std.fmt.comptimePrint("equip_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.inv_equip_ids[i] = id;
            self.makeSlotClickable(tree, id, hover_col);
            const cname = comptime std.fmt.comptimePrint("equip_count_{d}", .{i});
            self.inv_equip_count_ids[i] = tree.findById(cname) orelse NULL_WIDGET;
        }
        self.inv_offhand_id = tree.findById("inv_offhand") orelse NULL_WIDGET;
        self.makeSlotClickable(tree, self.inv_offhand_id, hover_col);
        self.inv_offhand_count_id = tree.findById("offhand_count") orelse NULL_WIDGET;
        self.inv_player_viewport_id = tree.findById("player_viewport") orelse NULL_WIDGET;
        if (self.inv_player_viewport_id != NULL_WIDGET) {
            if (tree.getData(self.inv_player_viewport_id)) |data| {
                data.panel.setAction("player_viewport_drag");
            }
        }
        // Backdrop click → drop carried item outside inventory
        const backdrop_id = tree.findById("inv_backdrop") orelse NULL_WIDGET;
        if (backdrop_id != NULL_WIDGET) {
            if (tree.getData(backdrop_id)) |data| {
                data.panel.setAction("inv_drop_outside");
            }
        }

        self.cursor_item_id = tree.findById("cursor_item") orelse NULL_WIDGET;
        self.cursor_count_id = tree.findById("cursor_count") orelse NULL_WIDGET;
        if (self.cursor_item_id != NULL_WIDGET) {
            if (tree.getWidget(self.cursor_item_id)) |w| {
                w.hit_transparent = true;
            }
            if (tree.getData(self.cursor_item_id)) |data| {
                data.panel.draw_isometric = true;
            }
            self.ui_manager.cursor_follow_widget = self.cursor_item_id;
            self.ui_manager.cursor_follow_child = self.cursor_count_id;
        }

        // Resolve inventory sprite UVs to image widgets
        if (self.ui_renderer) |ur| {
            if (ur.hud_atlas_loaded) {
                setImageAtlas(tree, tree.findById("inv_bg") orelse NULL_WIDGET, ur.inv_bg_rect);
                setImageAtlas(tree, tree.findById("inv_player_bg") orelse NULL_WIDGET, ur.inv_player_rect);
            }
        }

        // Resolve crafting panel background
        if (self.ui_renderer) |ur| {
            if (ur.hud_atlas_loaded) {
                setImageAtlas(tree, tree.findById("crafting_bg") orelse NULL_WIDGET, ur.crafting_bg_rect);
            }
        }

        // Cache crafting widget IDs (embedded in inventory screen)
        self.crafting_title_id = tree.findById("crafting_title") orelse NULL_WIDGET;
        self.recipe_list_id = tree.findById("recipe_list") orelse NULL_WIDGET;
        self.detail_icon_id = tree.findById("detail_icon") orelse NULL_WIDGET;
        self.detail_name_id = tree.findById("detail_name") orelse NULL_WIDGET;
        self.material_list_id = tree.findById("material_list") orelse NULL_WIDGET;
        self.craft_btn_id = tree.findById("craft_btn") orelse NULL_WIDGET;
        self.crafting_mode = .hand;
        self.selected_recipe = null;
        self.crafting_details_dirty = true;
        self.populateRecipeList();
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
        self.inv_slot_count_ids = .{NULL_WIDGET} ** GameState.HOTBAR_SIZE;
        self.inv_main_count_ids = .{NULL_WIDGET} ** GameState.INV_SIZE;
        self.inv_armor_count_ids = .{NULL_WIDGET} ** GameState.ARMOR_SLOTS;
        self.inv_equip_count_ids = .{NULL_WIDGET} ** GameState.EQUIP_SLOTS;
        self.inv_offhand_count_id = NULL_WIDGET;
        self.cursor_count_id = NULL_WIDGET;
        self.inv_player_viewport_id = NULL_WIDGET;
        self.cursor_item_id = NULL_WIDGET;
        self.ui_manager.cursor_follow_widget = NULL_WIDGET;
        self.ui_manager.cursor_follow_child = NULL_WIDGET;
        self.entity_visible = false;
        self.entity_viewport = .{ 0, 0, 0, 0 };
        // Reset crafting state
        self.resetCraftingWidgetIds();
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
        reg.register("toggle_game_mode", actionToggleGameMode, ctx);
        reg.register("cancel_create_world", actionCancelCreateWorld, ctx);
        reg.register("delete_world", actionDeleteWorld, ctx);
        reg.register("confirm_delete", actionConfirmDelete, ctx);
        reg.register("cancel_delete", actionCancelDelete, ctx);
        reg.register("backup_world", actionBackupWorld, ctx);
        reg.register("confirm_backup", actionConfirmBackup, ctx);
        reg.register("cancel_backup", actionCancelBackup, ctx);
        reg.register("edit_world", actionEditWorld, ctx);
        reg.register("edit_toggle_game_mode", actionEditToggleGameMode, ctx);
        reg.register("confirm_edit_world", actionConfirmEditWorld, ctx);
        reg.register("cancel_edit_world", actionCancelEditWorld, ctx);
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
        reg.register("change_fov", actionChangeFov, ctx);
        reg.register("inv_slot_click", actionInvSlotClick, ctx);
        reg.register("inv_drop_outside", actionInvDropOutside, ctx);
        reg.register("craft_recipe_select", actionCraftRecipeSelect, ctx);
        reg.register("craft_item", actionCraftItem, ctx);
        reg.register("crafting_close", actionCraftingClose, ctx);
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

            // Load display name; fall back to folder name
            if (app_config.loadDisplayName(self.allocator, name)) |display| {
                const dlen: u8 = @intCast(@min(display.len, MAX_DISPLAY_LEN));
                @memcpy(self.world_display_names[i][0..dlen], display[0..dlen]);
                self.world_display_lens[i] = dlen;
                self.allocator.free(display);
            } else {
                @memcpy(self.world_display_names[i][0..len], name[0..len]);
                self.world_display_lens[i] = len;
            }

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
                const display = self.world_display_names[i][0..self.world_display_lens[i]];
                if (!matchesSearch(display, filter)) continue;
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
                    data.label.setText(display);
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

        if (self.backup_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.backup_confirm_id)) |w| {
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

    pub fn showInventory(self: *MenuController, gs: *GameState) void {
        gs.inventory_open = true;
        self.loadScreen(.inventory);
        self.app_state = .inventory;
    }

    pub fn hideInventory(self: *MenuController, gs: ?*GameState) void {
        // Return carried item to inventory when closing
        if (gs) |g| {
            g.inventory_open = false;
            if (!g.carried_item.isEmpty()) {
                _ = g.addToInventory(g.carried_item);
                g.carried_item = GameState.Entity.ItemStack.EMPTY;
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

        const inv = gs.playerInv();

        // Update hotbar row
        for (0..GameState.HOTBAR_SIZE) |i| {
            const id = self.inv_slot_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, inv.hotbar[i]);
                }
            }
            updateCountLabel(tree, self.inv_slot_count_ids[i], inv.hotbar[i].count);
        }

        // Update main inventory
        for (0..GameState.INV_SIZE) |i| {
            const id = self.inv_main_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, inv.main[i]);
                }
            }
            updateCountLabel(tree, self.inv_main_count_ids[i], inv.main[i].count);
        }

        // Update armor slots
        for (0..GameState.ARMOR_SLOTS) |i| {
            const id = self.inv_armor_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, inv.armor[i]);
                }
            }
            updateCountLabel(tree, self.inv_armor_count_ids[i], inv.armor[i].count);
        }

        // Update equip slots
        for (0..GameState.EQUIP_SLOTS) |i| {
            const id = self.inv_equip_ids[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    updateSlotWidget(w, tree, id, inv.equip[i]);
                }
            }
            updateCountLabel(tree, self.inv_equip_count_ids[i], inv.equip[i].count);
        }

        // Update offhand
        if (self.inv_offhand_id != NULL_WIDGET) {
            const id = self.inv_offhand_id;
            if (tree.getWidget(id)) |w| {
                updateSlotWidget(w, tree, id, inv.offhand);
            }
        }
        updateCountLabel(tree, self.inv_offhand_count_id, inv.offhand.count);

        // Update cursor item (follows mouse when carrying)
        if (self.cursor_item_id != NULL_WIDGET) {
            const cid = self.cursor_item_id;
            if (tree.getWidget(cid)) |w| {
                if (!gs.carried_item.isEmpty()) {
                    const c = GameState.itemColor(gs.carried_item.block);
                    w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                    if (tree.getData(cid)) |data| {
                        data.panel.block_state = if (gs.carried_item.isTool())
                            BlockState.defaultState(.air)
                        else
                            BlockState.getDisplayState(gs.carried_item.block);
                    }
                    w.visible = true;
                } else {
                    w.visible = false;
                }
            }
        }
        updateCountLabel(tree, self.cursor_count_id, gs.carried_item.count);

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

        // Update crafting panel (embedded in inventory)
        self.updateCrafting(gs);
    }

    // ============================================================
    // Crafting screen
    // ============================================================

    fn cacheCraftingWidgetIds(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        self.crafting_title_id = tree.findById("crafting_title") orelse NULL_WIDGET;
        self.recipe_list_id = tree.findById("recipe_list") orelse NULL_WIDGET;
        self.detail_icon_id = tree.findById("detail_icon") orelse NULL_WIDGET;
        self.detail_name_id = tree.findById("detail_name") orelse NULL_WIDGET;
        self.material_list_id = tree.findById("material_list") orelse NULL_WIDGET;
        self.craft_btn_id = tree.findById("craft_btn") orelse NULL_WIDGET;

        // Resolve workbench background texture
        if (self.ui_renderer) |ur| {
            if (ur.hud_atlas_loaded) {
                setImageAtlas(tree, tree.findById("workbench_bg") orelse NULL_WIDGET, ur.workbench_bg_rect);
            }
        }
    }

    fn resetCraftingWidgetIds(self: *MenuController) void {
        self.crafting_title_id = NULL_WIDGET;
        self.recipe_list_id = NULL_WIDGET;
        self.detail_icon_id = NULL_WIDGET;
        self.detail_name_id = NULL_WIDGET;
        self.material_list_id = NULL_WIDGET;
        self.craft_btn_id = NULL_WIDGET;
        self.recipe_row_ids = .{NULL_WIDGET} ** MAX_RECIPES;
        self.visible_recipe_count = 0;
        self.selected_recipe = null;
        self.game_state = null;
    }

    pub fn showCrafting(self: *MenuController, gs: *GameState, mode: CraftingMode) void {
        self.crafting_mode = mode;
        self.selected_recipe = null;
        self.crafting_details_dirty = true;
        self.game_state = gs;
        self.loadScreen(.crafting);
        self.app_state = .crafting;

        // Set title
        if (self.crafting_title_id != NULL_WIDGET) {
            const tree = self.menuTree() orelse return;
            if (tree.getData(self.crafting_title_id)) |data| {
                data.label.setText(switch (mode) {
                    .hand => "HAND CRAFTING",
                    .workbench => "WORKBENCH",
                });
            }
        }

        self.populateRecipeList();
    }

    pub fn hideCrafting(self: *MenuController) void {
        self.game_state = null;
        self.unloadScreen(.crafting);
        self.app_state = .playing;
    }

    fn populateRecipeList(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        if (self.recipe_list_id == NULL_WIDGET) return;

        tree.clearChildren(self.recipe_list_id);
        self.visible_recipe_count = 0;

        for (Crafting.recipes, 0..) |*recipe, i| {
            if (self.visible_recipe_count >= MAX_RECIPES) break;
            // In hand mode, skip workbench-only recipes
            if (self.crafting_mode == .hand and recipe.requires_workbench) continue;

            const idx: u8 = @intCast(self.visible_recipe_count);
            self.recipe_indices[idx] = @intCast(i);

            const row_id = tree.addWidget(.panel, self.recipe_list_id) orelse return;
            if (tree.getWidget(row_id)) |w| {
                w.width = .fill;
                w.height = .{ .px = 32 };
                w.flex_direction = .row;
                w.cross_align = .center;
                w.padding = .{ .top = 2, .right = 8, .bottom = 2, .left = 6 };
                w.background = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.6 };
            }
            if (tree.getData(row_id)) |data| {
                data.panel.setAction("craft_recipe_select");
                data.panel.hover_color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.1 };
            }

            // Output icon (colored panel)
            const icon_id = tree.addWidget(.panel, row_id) orelse return;
            if (tree.getWidget(icon_id)) |w| {
                w.width = .{ .px = 24 };
                w.height = .{ .px = 24 };
                const c = GameState.itemColor(recipe.output.item);
                w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
            }
            if (tree.getData(icon_id)) |data| {
                if (!GameState.Item.isToolItem(recipe.output.item)) {
                    data.panel.block_state = BlockState.getDisplayState(recipe.output.item);
                }
                data.panel.draw_isometric = true;
            }

            // Recipe name label
            const name_id = tree.addWidget(.label, row_id) orelse return;
            if (tree.getWidget(name_id)) |w| {
                w.width = .fill;
                w.height = .auto;
                w.flex_grow = 1.0;
                w.margin = .{ .left = 8 };
            }
            if (tree.getData(name_id)) |data| {
                const output_name = GameState.itemName(recipe.output.item);
                data.label.setText(output_name);
                data.label.color = .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 };
                data.label.wrap = true;
            }

            // Count label
            if (recipe.output.count > 1) {
                const count_id = tree.addWidget(.label, row_id) orelse return;
                if (tree.getWidget(count_id)) |w| {
                    w.width = .auto;
                    w.height = .auto;
                    w.margin = .{ .right = 4 };
                }
                if (tree.getData(count_id)) |data| {
                    var buf: [8]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "x{d}", .{recipe.output.count}) catch "?";
                    data.label.setText(text);
                    data.label.color = .{ .r = 0.7, .g = 0.7, .b = 0.5, .a = 1.0 };
                }
            }

            self.recipe_row_ids[idx] = row_id;
            self.visible_recipe_count += 1;
        }
    }

    pub fn updateCrafting(self: *MenuController, gs: *GameState) void {
        if (self.app_state != .crafting and self.app_state != .inventory) {
            self.game_state = null;
            return;
        }
        self.game_state = gs;
        const tree = self.menuTree() orelse return;

        // Update recipe row colors based on craftability
        for (0..self.visible_recipe_count) |i| {
            const row_id = self.recipe_row_ids[i];
            if (row_id == NULL_WIDGET) continue;
            const recipe_idx = self.recipe_indices[i];
            const recipe = &Crafting.recipes[recipe_idx];
            const can = Crafting.canCraft(gs, recipe);
            const selected = if (self.selected_recipe) |sel| sel == i else false;

            if (tree.getWidget(row_id)) |w| {
                if (selected) {
                    w.background = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 0.8 };
                } else if (can) {
                    w.background = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.6 };
                } else {
                    w.background = .{ .r = 0.08, .g = 0.06, .b = 0.06, .a = 0.4 };
                }
            }
        }

        // Update detail panel only when selection or inventory changes
        if (self.crafting_details_dirty) {
            self.crafting_details_dirty = false;
            self.updateCraftingDetails(gs, tree);
        }

        // Update craft button state every frame (cheap)
        if (self.craft_btn_id != NULL_WIDGET) {
            if (self.selected_recipe) |sel| {
                if (sel < self.visible_recipe_count) {
                    const recipe_idx = self.recipe_indices[sel];
                    const can = Crafting.canCraft(gs, &Crafting.recipes[recipe_idx]);
                    if (tree.getWidget(self.craft_btn_id)) |w| {
                        if (can) {
                            w.background = .{ .r = 0.16, .g = 0.16, .b = 0.16, .a = 1.0 };
                        } else {
                            w.background = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.5 };
                        }
                    }
                }
            }
        }
    }

    fn updateCraftingDetails(self: *MenuController, gs: *GameState, tree: *WidgetTree) void {
        const sel = self.selected_recipe orelse {
            // No selection — clear detail panel
            if (self.detail_name_id != NULL_WIDGET) {
                if (tree.getData(self.detail_name_id)) |data| {
                    data.label.setText("Select a recipe");
                    data.label.color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
                }
            }
            if (self.detail_icon_id != NULL_WIDGET) {
                if (tree.getWidget(self.detail_icon_id)) |w| {
                    w.background = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                }
                if (tree.getData(self.detail_icon_id)) |data| {
                    data.panel.block_state = BlockState.defaultState(.air);
                }
            }
            if (self.material_list_id != NULL_WIDGET) {
                tree.clearChildren(self.material_list_id);
            }
            // Disable craft button
            if (self.craft_btn_id != NULL_WIDGET) {
                if (tree.getWidget(self.craft_btn_id)) |w| {
                    w.background = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 0.5 };
                }
            }
            return;
        };

        if (sel >= self.visible_recipe_count) return;
        const recipe_idx = self.recipe_indices[sel];
        const recipe = &Crafting.recipes[recipe_idx];
        const can = Crafting.canCraft(gs, recipe);

        // Update output icon
        if (self.detail_icon_id != NULL_WIDGET) {
            if (tree.getWidget(self.detail_icon_id)) |w| {
                const c = GameState.itemColor(recipe.output.item);
                w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
            }
            if (tree.getData(self.detail_icon_id)) |data| {
                if (!GameState.Item.isToolItem(recipe.output.item)) {
                    data.panel.block_state = BlockState.getDisplayState(recipe.output.item);
                } else {
                    data.panel.block_state = BlockState.defaultState(.air);
                }
                data.panel.draw_isometric = true;
            }
        }

        // Update output name
        if (self.detail_name_id != NULL_WIDGET) {
            if (tree.getData(self.detail_name_id)) |data| {
                const name = GameState.itemName(recipe.output.item);
                var buf: [72]u8 = undefined;
                if (recipe.output.count > 1) {
                    const text = std.fmt.bufPrint(&buf, "{s} x{d}", .{ name, recipe.output.count }) catch name;
                    data.label.setText(text);
                } else {
                    data.label.setText(name);
                }
                data.label.color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
            }
        }

        // Update material list
        if (self.material_list_id != NULL_WIDGET) {
            tree.clearChildren(self.material_list_id);
            for (0..recipe.input_count) |i| {
                const inp = recipe.inputs[i];
                const have = Crafting.countItem(gs, inp.item);
                const enough = have >= inp.count;

                const mat_row = tree.addWidget(.panel, self.material_list_id) orelse return;
                if (tree.getWidget(mat_row)) |w| {
                    w.width = .fill;
                    w.height = .{ .px = 24 };
                    w.flex_direction = .row;
                    w.cross_align = .center;
                    w.padding = .{ .left = 4 };
                    w.gap = 6;
                }

                // Material icon
                const mat_icon = tree.addWidget(.panel, mat_row) orelse return;
                if (tree.getWidget(mat_icon)) |w| {
                    w.width = .{ .px = 18 };
                    w.height = .{ .px = 18 };
                    const c = GameState.itemColor(inp.item);
                    w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                }
                if (tree.getData(mat_icon)) |data| {
                    if (!GameState.Item.isToolItem(inp.item)) {
                        data.panel.block_state = BlockState.getDisplayState(inp.item);
                    }
                    data.panel.draw_isometric = true;
                }

                // Material text: "name  have/need"
                const mat_label = tree.addWidget(.label, mat_row) orelse return;
                if (tree.getWidget(mat_label)) |w| {
                    w.width = .fill;
                    w.height = .auto;
                    w.flex_grow = 1.0;
                }
                if (tree.getData(mat_label)) |data| {
                    const mat_name = GameState.itemName(inp.item);
                    var mat_buf: [80]u8 = undefined;
                    const text = std.fmt.bufPrint(&mat_buf, "{s}  {d}/{d}", .{ mat_name, have, inp.count }) catch mat_name;
                    data.label.setText(text);
                    if (enough) {
                        data.label.color = .{ .r = 0.5, .g = 1.0, .b = 0.5, .a = 1.0 };
                    } else {
                        data.label.color = .{ .r = 1.0, .g = 0.4, .b = 0.4, .a = 1.0 };
                    }
                }
            }
        }

        // Update craft button
        if (self.craft_btn_id != NULL_WIDGET) {
            if (tree.getWidget(self.craft_btn_id)) |w| {
                if (can) {
                    w.background = .{ .r = 0.2, .g = 0.33, .b = 0.53, .a = 1.0 };
                } else {
                    w.background = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 0.5 };
                }
            }
        }
    }

    fn actionCraftRecipeSelect(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const pressed = self.ui_manager.pressed_widget;
        if (pressed == NULL_WIDGET) return;

        for (0..self.visible_recipe_count) |i| {
            if (self.recipe_row_ids[i] == pressed) {
                self.selected_recipe = @intCast(i);
                self.crafting_details_dirty = true;
                return;
            }
        }
    }

    fn actionCraftItem(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const gs = self.game_state orelse return;
        const sel = self.selected_recipe orelse return;
        if (sel >= self.visible_recipe_count) return;
        const recipe_idx = self.recipe_indices[sel];
        if (Crafting.craft(gs, &Crafting.recipes[recipe_idx])) {
            self.crafting_details_dirty = true;
        }
    }

    fn actionCraftingClose(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.hideCrafting();
    }

    pub fn showTitleMenu(self: *MenuController) void {
        // Unload any gameplay screens (pause, inventory, hud)
        if (self.app_state == .pause_menu) {
            self.unloadScreen(.pause);
        }
        if (self.app_state == .inventory) {
            // Return carried item before closing
            if (self.game_state) |gs| {
                gs.carried_item = GameState.Entity.ItemStack.EMPTY;
            }
            self.game_state = null;
            self.unloadScreen(.inventory);
        }
        if (self.app_state == .crafting) {
            self.game_state = null;
            self.unloadScreen(.crafting);
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

    pub fn updateHud(self: *MenuController, gs: *const GameState, gamepad: *const Gamepad) void {
        if (self.hud_binder == null) return;
        const tree = self.hudTree() orelse return;
        if (tree.getWidget(tree.root)) |root| {
            root.visible = gs.show_ui;
        }
        (&self.hud_binder.?).update(tree, gs, gamepad);
    }

    pub fn getSelectedWorldName(self: *const MenuController) []const u8 {
        if (self.world_count == 0) return "";
        const sel = self.selection;
        if (sel >= self.world_count) return "";
        return self.world_names[sel][0..self.world_name_lens[sel]];
    }

    pub fn getSelectedDisplayName(self: *const MenuController) []const u8 {
        if (self.world_count == 0) return "";
        const sel = self.selection;
        if (sel >= self.world_count) return "";
        return self.world_display_names[sel][0..self.world_display_lens[sel]];
    }

    pub fn getEditWorldOriginalName(self: *const MenuController) []const u8 {
        if (self.edit_world_name_len == 0) return "";
        return self.edit_world_name[0..self.edit_world_name_len];
    }

    pub fn getEditWorldNewName(self: *const MenuController) []const u8 {
        if (self.edit_world_name_input_id == NULL_WIDGET) return "";
        if (self.ui_manager.screen_count == 0) return "";
        const tree = &self.ui_manager.screens[self.ui_manager.screen_count - 1].tree;
        const data = tree.getDataConst(self.edit_world_name_input_id) orelse return "";
        return data.text_input.getText();
    }

    pub fn getInputName(self: *const MenuController) []const u8 {
        if (self.app_state != .create_world) return "";
        if (self.ui_manager.screen_count == 0) return "";
        const tree = &self.ui_manager.screens[self.ui_manager.screen_count - 1].tree;
        if (self.create_world_input_id == NULL_WIDGET) return "";
        const data = tree.getDataConst(self.create_world_input_id) orelse return "";
        return data.text_input.getText();
    }

    pub fn getInputSeed(self: *const MenuController) ?u64 {
        if (self.app_state != .create_world) return null;
        if (self.seed_input_id == NULL_WIDGET) return null;
        if (self.ui_manager.screen_count == 0) return null;
        const tree = &self.ui_manager.screens[self.ui_manager.screen_count - 1].tree;
        const data = tree.getDataConst(self.seed_input_id) orelse return null;
        const text = data.text_input.getText();
        if (text.len == 0) return null;
        return std.fmt.parseInt(u64, text, 10) catch {
            // Hash the string into a seed
            var hash: u64 = 5381;
            for (text) |c| {
                hash = ((hash << 5) +% hash) +% c;
            }
            return hash;
        };
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
                const display = self.getSelectedDisplayName();
                var buf: [96]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Delete \"{s}\"?", .{display}) catch "Delete?";
                data.label.setText(text);
            }
        }
    }

    // ============================================================
    // Backup confirm (modal within singleplayer screen)
    // ============================================================

    pub fn showBackupConfirm(self: *MenuController) void {
        if (self.world_count == 0) return;
        const tree = self.menuTree() orelse return;
        if (self.backup_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.backup_confirm_id)) |w| {
                w.visible = true;
            }
        }
        if (self.backup_label_id != NULL_WIDGET) {
            if (tree.getData(self.backup_label_id)) |data| {
                const display = self.getSelectedDisplayName();
                var buf: [96]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Backup \"{s}\"?", .{display}) catch "Backup?";
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

    fn actionToggleGameMode(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.selected_game_mode = switch (self.selected_game_mode) {
            .creative => .survival,
            .survival => .creative,
        };
        self.updateGameModeLabel();
    }

    fn updateGameModeLabel(self: *MenuController) void {
        if (self.game_mode_label_id == NULL_WIDGET) return;
        const tree = self.menuTree() orelse return;
        if (tree.getData(self.game_mode_label_id)) |data| {
            data.label.setText(switch (self.selected_game_mode) {
                .creative => "Game Mode: Creative",
                .survival => "Game Mode: Survival",
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

    fn actionBackupWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).showBackupConfirm();
    }

    fn actionConfirmBackup(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.action = .backup_world;
        const tree = self.menuTree() orelse return;
        if (self.backup_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.backup_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionCancelBackup(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.menuTree() orelse return;
        if (self.backup_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.backup_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionEditWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.world_count == 0) return;
        const name = self.getSelectedWorldName();
        if (name.len == 0) return;
        const len: u8 = @intCast(@min(name.len, MAX_NAME_LEN));
        @memcpy(self.edit_world_name[0..len], name[0..len]);
        self.edit_world_name_len = len;
        self.transitionTo(.edit_world);
    }

    fn actionEditToggleGameMode(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.edit_game_mode = switch (self.edit_game_mode) {
            .creative => .survival,
            .survival => .creative,
        };
        self.updateEditGameModeLabel();
    }

    fn actionConfirmEditWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.action = .edit_world;
    }

    fn actionCancelEditWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).transitionTo(.singleplayer_menu);
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

    fn actionChangeFov(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const opts = self.options orelse return;
        const tree = self.menuTree() orelse return;
        if (self.fov_slider_id != NULL_WIDGET) {
            if (tree.getData(self.fov_slider_id)) |data| {
                opts.fov = @round(data.slider.value);
                data.slider.value = opts.fov;
            }
        }
        self.updateFovLabel();
        opts.save(self.allocator);
    }

    fn updateFovLabel(self: *MenuController) void {
        const tree = self.menuTree() orelse return;
        const opts = self.options orelse return;
        if (self.fov_label_id != NULL_WIDGET) {
            if (tree.getData(self.fov_label_id)) |data| {
                const val: i32 = @intFromFloat(opts.fov);
                var buf: [8]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
                data.label.setText(slice);
            }
        }
    }

    /// Resolve a widget ID to a unified inventory slot index.
    fn resolveSlotFromWidget(self: *const MenuController, widget_id: WidgetId) ?u8 {
        if (widget_id == NULL_WIDGET) return null;
        for (self.inv_slot_ids, 0..) |id, i| {
            if (id == widget_id) return @intCast(i); // hotbar: 0-8
        }
        for (self.inv_main_ids, 0..) |id, i| {
            if (id == widget_id) return @as(u8, GameState.HOTBAR_SIZE) + @as(u8, @intCast(i)); // main: 9-44
        }
        for (self.inv_armor_ids, 0..) |id, i| {
            if (id == widget_id) return @as(u8, GameState.HOTBAR_SIZE + GameState.INV_SIZE) + @as(u8, @intCast(i));
        }
        for (self.inv_equip_ids, 0..) |id, i| {
            if (id == widget_id) return @as(u8, GameState.HOTBAR_SIZE + GameState.INV_SIZE + GameState.ARMOR_SLOTS) + @as(u8, @intCast(i));
        }
        if (self.inv_offhand_id == widget_id) return GameState.HOTBAR_SIZE + GameState.INV_SIZE + GameState.ARMOR_SLOTS + GameState.EQUIP_SLOTS;
        return null;
    }

    /// Get the inventory slot index under the mouse cursor, if any.
    pub fn hoveredSlot(self: *const MenuController) ?u8 {
        return self.resolveSlotFromWidget(self.ui_manager.hover_widget);
    }

    fn actionInvSlotClick(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const pressed = self.ui_manager.pressed_widget;
        const slot = self.resolveSlotFromWidget(pressed);

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

    fn actionInvDropOutside(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const gs = self.game_state orelse return;
        if (gs.carried_item.isEmpty()) return;
        const drop_all = self.ui_manager.last_button != glfw.GLFW_MOUSE_BUTTON_RIGHT;
        gs.dropCarried(drop_all);
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

    fn updateCountLabel(tree: *WidgetTree, cid: WidgetId, count: u8) void {
        if (cid == NULL_WIDGET) return;
        if (tree.getWidget(cid)) |cw| {
            if (count > 1) {
                cw.visible = true;
                if (tree.getData(cid)) |data| {
                    var buf: [4]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "?";
                    data.label.setText(text);
                }
            } else {
                cw.visible = false;
            }
        }
    }

    fn updateSlotWidget(w: *Widget.Widget, tree: *WidgetTree, id: WidgetId, stack: GameState.Entity.ItemStack) void {
        if (!stack.isEmpty()) {
            const c = GameState.itemColor(stack.block);
            w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
            if (tree.getData(id)) |data| {
                data.panel.block_state = if (stack.isTool())
                    BlockState.defaultState(.air)
                else
                    BlockState.getDisplayState(stack.block);
            }
            const name = GameState.itemName(stack.block);
            const len: u8 = @intCast(@min(name.len, 64));
            @memcpy(w.tooltip[0..len], name[0..len]);
            w.tooltip_len = len;
        } else {
            w.background = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            if (tree.getData(id)) |data| {
                data.panel.block_state = BlockState.defaultState(.air);
            }
            w.tooltip_len = 0;
        }
    }

    fn getSelf(ctx: ?*anyopaque) *MenuController {
        return @ptrCast(@alignCast(ctx.?));
    }
};
