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
const app_config = @import("../app_config.zig");
const Options = @import("../Options.zig");

const log = std.log.scoped(.UI);

pub const MAX_WORLDS: u8 = 32;
pub const MAX_NAME_LEN: u8 = 32;

pub const AppState = enum { title_menu, singleplayer_menu, loading, playing, pause_menu, saving };
pub const Action = enum { load_world, create_world, delete_world, resume_game, return_to_title, quit };

pub const MenuController = struct {
    ui_manager: *UiManager,
    allocator: std.mem.Allocator,
    app_state: AppState = .title_menu,
    action: ?Action = null,

    world_names: [MAX_WORLDS][MAX_NAME_LEN]u8 = undefined,
    world_name_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
    world_count: u8 = 0,
    selection: u8 = 0,

    title_screen_loaded: bool = false,
    singleplayer_screen_loaded: bool = false,
    create_world_screen_loaded: bool = false,
    pause_screen_loaded: bool = false,
    hud_screen_loaded: bool = false,
    controls_screen_loaded: bool = false,

    hud_binder: ?HudBinder = null,
    options: ?*Options = null,

    // Controls screen state
    controls_from_pause: bool = false,
    rebinding_action: ?Options.Action = null,
    keybind_list_id: WidgetId = NULL_WIDGET,
    rebind_hint_id: WidgetId = NULL_WIDGET,
    keybind_button_ids: [Options.Action.count]WidgetId = .{NULL_WIDGET} ** Options.Action.count,

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

        if (ui_manager.loadScreenFromFile("title_menu.xml", allocator)) {
            self.title_screen_loaded = true;
            self.cacheTitleWidgetIds();
        } else {
            log.err("Failed to load title_menu.xml", .{});
        }

        return self;
    }

    fn cacheTitleWidgetIds(self: *MenuController) void {
        const tree = self.titleTree() orelse return;
        self.coming_soon_modal_id = tree.findById("coming_soon_modal") orelse NULL_WIDGET;
    }

    fn cacheSingleplayerWidgetIds(self: *MenuController) void {
        const tree = self.singleplayerTree() orelse return;
        self.world_list_id = tree.findById("world_list") orelse NULL_WIDGET;
        self.no_worlds_label_id = tree.findById("no_worlds_label") orelse NULL_WIDGET;
        self.delete_confirm_id = tree.findById("delete_confirm") orelse NULL_WIDGET;
        self.delete_label_id = tree.findById("delete_label") orelse NULL_WIDGET;
        self.world_search_input_id = tree.findById("world_search_input") orelse NULL_WIDGET;
    }

    fn cacheCreateWorldWidgetIds(self: *MenuController) void {
        const tree = self.createWorldTree() orelse return;
        self.create_world_input_id = tree.findById("create_world_input") orelse NULL_WIDGET;
        self.world_type_label_id = tree.findById("world_type_label") orelse NULL_WIDGET;
    }

    fn titleTree(self: *MenuController) ?*WidgetTree {
        if (!self.title_screen_loaded) return null;
        if (self.ui_manager.screen_count == 0) return null;
        if (!self.ui_manager.screens[0].active) return null;
        return &self.ui_manager.screens[0].tree;
    }

    fn singleplayerTree(self: *MenuController) ?*WidgetTree {
        if (!self.singleplayer_screen_loaded) return null;
        if (self.ui_manager.screen_count == 0) return null;
        if (!self.ui_manager.screens[0].active) return null;
        return &self.ui_manager.screens[0].tree;
    }

    fn createWorldTree(self: *MenuController) ?*WidgetTree {
        if (!self.create_world_screen_loaded) return null;
        if (self.ui_manager.screen_count == 0) return null;
        if (!self.ui_manager.screens[0].active) return null;
        return &self.ui_manager.screens[0].tree;
    }

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
    }

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
        const tree = self.singleplayerTree() orelse return "";
        const data = tree.getDataConst(self.world_search_input_id) orelse return "";
        return data.text_input.getText();
    }

    fn matchesSearch(name: []const u8, filter: []const u8) bool {
        if (filter.len == 0) return true;
        if (filter.len > name.len) return false;
        // Case-insensitive substring match
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
        const tree = self.singleplayerTree() orelse return;
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
                    w.background = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1.0 };
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

    pub fn showPauseMenu(self: *MenuController) void {
        if (self.ui_manager.loadScreenFromFile("pause_menu.xml", self.allocator)) {
            self.pause_screen_loaded = true;
        } else {
            log.err("Failed to load pause_menu.xml", .{});
        }
        self.app_state = .pause_menu;
    }

    pub fn hidePauseMenu(self: *MenuController) void {
        if (self.pause_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.pause_screen_loaded = false;
        }
        self.app_state = .playing;
    }

    pub fn showTitleMenu(self: *MenuController) void {
        if (self.pause_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.pause_screen_loaded = false;
        }
        if (self.hud_screen_loaded) {
            self.unloadHud();
        }
        if (self.controls_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.controls_screen_loaded = false;
            self.resetControlsWidgetIds();
        }
        if (self.create_world_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.create_world_screen_loaded = false;
            self.create_world_input_id = NULL_WIDGET;
            self.world_type_label_id = NULL_WIDGET;
        }
        if (self.singleplayer_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        if (!self.title_screen_loaded or self.ui_manager.screen_count == 0) {
            if (self.ui_manager.loadScreenFromFile("title_menu.xml", self.allocator)) {
                self.title_screen_loaded = true;
                self.cacheTitleWidgetIds();
            }
        }
        self.app_state = .title_menu;
    }

    pub fn hideTitleMenu(self: *MenuController) void {
        if (self.controls_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.controls_screen_loaded = false;
            self.resetControlsWidgetIds();
        }
        if (self.create_world_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.create_world_screen_loaded = false;
            self.create_world_input_id = NULL_WIDGET;
            self.world_type_label_id = NULL_WIDGET;
        }
        if (self.singleplayer_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        if (self.title_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.title_screen_loaded = false;
        }
    }


    fn hudTree(self: *MenuController) ?*WidgetTree {
        if (!self.hud_screen_loaded) return null;
        if (self.ui_manager.screen_count == 0) return null;
        if (!self.ui_manager.screens[0].active) return null;
        return &self.ui_manager.screens[0].tree;
    }

    pub fn loadHud(self: *MenuController, ui_renderer: *const UiRenderer) void {
        if (self.hud_screen_loaded) return;
        if (self.ui_manager.loadScreenFromFile("hud.xml", self.allocator)) {
            self.hud_screen_loaded = true;
            const tree = self.hudTree() orelse return;
            var binder = HudBinder.init(tree);
            binder.resolveSprites(tree, ui_renderer);
            self.hud_binder = binder;
        } else {
            log.err("Failed to load hud.xml", .{});
        }
    }

    pub fn unloadHud(self: *MenuController) void {
        if (!self.hud_screen_loaded) return;
        if (self.pause_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.pause_screen_loaded = false;
        }
        if (self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
        }
        self.hud_screen_loaded = false;
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
        const tree: *const WidgetTree = if (self.create_world_screen_loaded and self.ui_manager.screen_count > 0)
            &self.ui_manager.screens[0].tree
        else
            return "";
        if (self.create_world_input_id == NULL_WIDGET) return "";
        const data = tree.getDataConst(self.create_world_input_id) orelse return "";
        return data.text_input.getText();
    }

    fn resetSingleplayerWidgetIds(self: *MenuController) void {
        self.world_list_id = NULL_WIDGET;
        self.no_worlds_label_id = NULL_WIDGET;
        self.delete_confirm_id = NULL_WIDGET;
        self.delete_label_id = NULL_WIDGET;
        self.world_search_input_id = NULL_WIDGET;
    }


    fn actionPlayWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.world_count > 0) {
            self.action = .load_world;
        }
    }

    fn actionShowCreateWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.create_world_screen_loaded) return;
        if (self.singleplayer_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        self.selected_world_type = .normal;
        if (self.ui_manager.loadScreenFromFile("create_world_menu.xml", self.allocator)) {
            self.create_world_screen_loaded = true;
            self.cacheCreateWorldWidgetIds();
        } else {
            log.err("Failed to load create_world_menu.xml", .{});
        }
    }

    fn actionConfirmCreateWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const name = self.getInputName();
        if (name.len > 0) {
            self.action = .create_world;
        }
    }

    fn actionToggleWorldType(ctx: ?*anyopaque) void {
        const WorldType = @import("../world/WorldState.zig").WorldType;
        const self = getSelf(ctx);
        self.selected_world_type = switch (self.selected_world_type) {
            .normal => .debug,
            .debug => .normal,
        };
        self.updateWorldTypeLabel();
        _ = WorldType;
    }

    fn updateWorldTypeLabel(self: *MenuController) void {
        if (self.world_type_label_id == NULL_WIDGET) return;
        const tree = self.createWorldTree() orelse return;
        if (tree.getData(self.world_type_label_id)) |data| {
            data.label.setText(switch (self.selected_world_type) {
                .normal => "World Type: Normal",
                .debug => "World Type: Debug",
            });
        }
    }

    fn actionCancelCreateWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.create_world_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.create_world_screen_loaded = false;
            self.create_world_input_id = NULL_WIDGET;
            self.world_type_label_id = NULL_WIDGET;
        }
        if (self.ui_manager.loadScreenFromFile("singleplayer_menu.xml", self.allocator)) {
            self.singleplayer_screen_loaded = true;
            self.cacheSingleplayerWidgetIds();
            self.refreshWorldList();
            self.app_state = .singleplayer_menu;
        } else {
            log.err("Failed to load singleplayer_menu.xml", .{});
        }
    }

    pub fn showDeleteConfirm(self: *MenuController) void {
        if (self.world_count == 0) return;

        const tree = self.singleplayerTree() orelse return;
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

    fn actionDeleteWorld(ctx: ?*anyopaque) void {
        getSelf(ctx).showDeleteConfirm();
    }

    fn actionConfirmDelete(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.action = .delete_world;
        const tree = self.singleplayerTree() orelse return;
        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = false;
            }
        }
    }

    fn actionCancelDelete(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.singleplayerTree() orelse return;
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
        const self = getSelf(ctx);
        self.action = .return_to_title;
    }

    fn actionQuitGame(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        self.action = .quit;
    }

    fn actionWorldSelect(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.singleplayerTree() orelse return;
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
        const self = getSelf(ctx);
        self.populateWorldListWidget();
    }

    fn actionShowSingleplayer(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.singleplayer_screen_loaded) return;
        if (self.title_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.title_screen_loaded = false;
        }
        if (self.ui_manager.loadScreenFromFile("singleplayer_menu.xml", self.allocator)) {
            self.singleplayer_screen_loaded = true;
            self.cacheSingleplayerWidgetIds();
            self.refreshWorldList();
            self.app_state = .singleplayer_menu;
        } else {
            log.err("Failed to load singleplayer_menu.xml", .{});
        }
    }

    fn actionBackToTitle(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.singleplayer_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        if (self.ui_manager.loadScreenFromFile("title_menu.xml", self.allocator)) {
            self.title_screen_loaded = true;
            self.cacheTitleWidgetIds();
        } else {
            log.err("Failed to load title_menu.xml", .{});
        }
        self.app_state = .title_menu;
    }

    fn actionShowComingSoon(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.titleTree() orelse return;
        if (self.coming_soon_modal_id != NULL_WIDGET) {
            if (tree.getWidget(self.coming_soon_modal_id)) |w| {
                w.visible = true;
            }
        }
    }

    fn actionDismissModal(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const tree = self.titleTree() orelse return;
        if (self.coming_soon_modal_id != NULL_WIDGET) {
            if (tree.getWidget(self.coming_soon_modal_id)) |w| {
                w.visible = false;
            }
        }
    }

    // ============================================================
    // Controls screen
    // ============================================================

    fn controlsTree(self: *MenuController) ?*WidgetTree {
        if (!self.controls_screen_loaded) return null;
        if (self.ui_manager.screen_count == 0) return null;
        const screen = &self.ui_manager.screens[self.ui_manager.screen_count - 1];
        if (!screen.active) return null;
        return &screen.tree;
    }

    fn cacheControlsWidgetIds(self: *MenuController) void {
        const tree = self.controlsTree() orelse return;
        self.keybind_list_id = tree.findById("keybind_list") orelse NULL_WIDGET;
        self.rebind_hint_id = tree.findById("rebind_hint") orelse NULL_WIDGET;
    }

    fn resetControlsWidgetIds(self: *MenuController) void {
        self.keybind_list_id = NULL_WIDGET;
        self.rebind_hint_id = NULL_WIDGET;
        self.keybind_button_ids = .{NULL_WIDGET} ** Options.Action.count;
        self.rebinding_action = null;
    }

    fn populateKeybindList(self: *MenuController) void {
        const tree = self.controlsTree() orelse return;
        const opts = self.options orelse return;
        if (self.keybind_list_id == NULL_WIDGET) return;

        tree.clearChildren(self.keybind_list_id);

        inline for (@typeInfo(Options.Action).@"enum".fields) |field| {
            const action: Options.Action = @enumFromInt(field.value);
            const display = action.displayName();
            const binding = opts.bindings[field.value];
            const key_display = Options.inputDisplayName(binding);

            // Row panel
            const row_id = tree.addWidget(.panel, self.keybind_list_id) orelse return;
            if (tree.getWidget(row_id)) |w| {
                w.width = .fill;
                w.height = .{ .px = 28 };
                w.flex_direction = .row;
                w.cross_align = .center;
                w.padding = .{ .top = 2, .right = 8, .bottom = 2, .left = 8 };
                w.background = .{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 0.5 };
            }

            // Action name label (left)
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

            // Keybind button (right)
            const btn_id = tree.addWidget(.button, row_id) orelse return;
            if (tree.getWidget(btn_id)) |w| {
                w.width = .{ .px = 140 };
                w.height = .{ .px = 24 };
                w.background = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1.0 };
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

    fn updateKeybindButton(self: *MenuController, action: Options.Action) void {
        const tree = self.controlsTree() orelse return;
        const opts = self.options orelse return;
        const idx = @intFromEnum(action);
        const btn_id = self.keybind_button_ids[idx];
        if (btn_id == NULL_WIDGET) return;
        if (tree.getData(btn_id)) |data| {
            data.button.setText(Options.inputDisplayName(opts.bindings[idx]));
            data.button.text_color = .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 };
        }
        if (tree.getWidget(btn_id)) |w| {
            w.background = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1.0 };
        }
    }

    fn setRebindingVisual(self: *MenuController, action: Options.Action) void {
        const tree = self.controlsTree() orelse return;
        const idx = @intFromEnum(action);
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
        const tree = self.controlsTree() orelse return;
        if (self.rebind_hint_id != NULL_WIDGET) {
            if (tree.getData(self.rebind_hint_id)) |data| {
                data.label.setText("Click a key to rebind");
                data.label.color = .{ .r = 0.53, .g = 0.53, .b = 0.53, .a = 1.0 };
            }
        }
    }

    /// Called from main.zig when a key is pressed during rebinding.
    pub fn handleRebindKey(self: *MenuController, code: Options.InputCode) void {
        const action = self.rebinding_action orelse return;
        const opts = self.options orelse return;

        opts.bindings[@intFromEnum(action)] = code;
        self.updateKeybindButton(action);
        self.rebinding_action = null;
        self.clearRebindHint();
        opts.save(self.allocator);
    }

    /// Cancel active rebinding without changing anything.
    pub fn cancelRebind(self: *MenuController) void {
        if (self.rebinding_action) |action| {
            self.updateKeybindButton(action);
            self.rebinding_action = null;
            self.clearRebindHint();
        }
    }

    fn actionShowControls(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.controls_screen_loaded) return;
        self.controls_from_pause = false;
        if (self.title_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.title_screen_loaded = false;
        }
        self.openControlsScreen();
    }

    fn actionShowControlsPause(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.controls_screen_loaded) return;
        self.controls_from_pause = true;
        if (self.pause_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.pause_screen_loaded = false;
        }
        self.openControlsScreen();
    }

    fn openControlsScreen(self: *MenuController) void {
        if (self.ui_manager.loadScreenFromFile("controls_menu.xml", self.allocator)) {
            self.controls_screen_loaded = true;
            self.cacheControlsWidgetIds();
            self.populateKeybindList();
        } else {
            log.err("Failed to load controls_menu.xml", .{});
        }
    }

    pub fn closeControls(self: *MenuController) void {
        self.rebinding_action = null;
        if (self.controls_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.controls_screen_loaded = false;
            self.resetControlsWidgetIds();
        }
        if (self.controls_from_pause) {
            self.controls_from_pause = false;
            self.showPauseMenu();
        } else {
            if (self.ui_manager.loadScreenFromFile("title_menu.xml", self.allocator)) {
                self.title_screen_loaded = true;
                self.cacheTitleWidgetIds();
            }
            self.app_state = .title_menu;
        }
    }

    fn actionCloseControls(ctx: ?*anyopaque) void {
        getSelf(ctx).closeControls();
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
        // Find which button was pressed by checking ui_manager.pressed_widget
        const pressed = self.ui_manager.pressed_widget;
        if (pressed == NULL_WIDGET) return;

        // Cancel any active rebind
        if (self.rebinding_action) |prev| {
            self.updateKeybindButton(prev);
        }

        // Find which action this button belongs to
        for (&self.keybind_button_ids, 0..) |btn_id, i| {
            if (btn_id == pressed) {
                const action: Options.Action = @enumFromInt(i);
                self.rebinding_action = action;
                self.setRebindingVisual(action);
                return;
            }
        }
    }

    fn getSelf(ctx: ?*anyopaque) *MenuController {
        return @ptrCast(@alignCast(ctx.?));
    }
};
