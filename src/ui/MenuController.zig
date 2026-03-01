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

const log = std.log.scoped(.UI);

pub const MAX_WORLDS: u8 = 32;
pub const MAX_NAME_LEN: u8 = 32;

pub const AppState = enum { title_menu, singleplayer_menu, playing, pause_menu };
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
    pause_screen_loaded: bool = false,
    hud_screen_loaded: bool = false,

    hud_binder: ?HudBinder = null,

    coming_soon_modal_id: WidgetId = NULL_WIDGET,

    world_list_id: WidgetId = NULL_WIDGET,
    no_worlds_label_id: WidgetId = NULL_WIDGET,
    delete_confirm_id: WidgetId = NULL_WIDGET,
    delete_label_id: WidgetId = NULL_WIDGET,
    world_name_input_id: WidgetId = NULL_WIDGET,

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
        self.world_name_input_id = tree.findById("world_name_input") orelse NULL_WIDGET;
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

    pub fn registerActions(self: *MenuController) void {
        const reg = &self.ui_manager.registry;
        const ctx: *anyopaque = @ptrCast(self);
        reg.register("play_world", actionPlayWorld, ctx);
        reg.register("create_world", actionCreateWorld, ctx);
        reg.register("delete_world", actionDeleteWorld, ctx);
        reg.register("confirm_delete", actionConfirmDelete, ctx);
        reg.register("cancel_delete", actionCancelDelete, ctx);
        reg.register("resume_game", actionResumeGame, ctx);
        reg.register("return_to_title", actionReturnToTitle, ctx);
        reg.register("quit_game", actionQuitGame, ctx);
        reg.register("world_select", actionWorldSelect, ctx);
        reg.register("show_singleplayer", actionShowSingleplayer, ctx);
        reg.register("back_to_title", actionBackToTitle, ctx);
        reg.register("show_coming_soon", actionShowComingSoon, ctx);
        reg.register("dismiss_modal", actionDismissModal, ctx);
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

    fn populateWorldListWidget(self: *MenuController) void {
        const tree = self.singleplayerTree() orelse return;

        if (self.world_list_id != NULL_WIDGET) {
            if (tree.getData(self.world_list_id)) |data| {
                data.list_view.item_count = self.world_count;
                data.list_view.selected_index = self.selection;
                data.list_view.scroll_offset = 0;
            }

            tree.clearChildren(self.world_list_id);
            for (0..self.world_count) |i| {
                const name = self.world_names[i][0..self.world_name_lens[i]];

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
        }

        if (self.no_worlds_label_id != NULL_WIDGET) {
            if (tree.getWidget(self.no_worlds_label_id)) |w| {
                w.visible = (self.world_count == 0);
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
        binder.update(tree, gs);
    }

    pub fn getSelectedWorldName(self: *const MenuController) []const u8 {
        if (self.world_count == 0) return "";
        const sel = self.selection;
        if (sel >= self.world_count) return "";
        return self.world_names[sel][0..self.world_name_lens[sel]];
    }

    pub fn getInputName(self: *const MenuController) []const u8 {
        const tree: *const WidgetTree = if (self.singleplayer_screen_loaded and self.ui_manager.screen_count > 0)
            &self.ui_manager.screens[0].tree
        else
            return "";
        if (self.world_name_input_id == NULL_WIDGET) return "";
        const data = tree.getDataConst(self.world_name_input_id) orelse return "";
        return data.text_input.getText();
    }

    fn resetSingleplayerWidgetIds(self: *MenuController) void {
        self.world_list_id = NULL_WIDGET;
        self.no_worlds_label_id = NULL_WIDGET;
        self.delete_confirm_id = NULL_WIDGET;
        self.delete_label_id = NULL_WIDGET;
        self.world_name_input_id = NULL_WIDGET;
    }


    fn actionPlayWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        if (self.world_count > 0) {
            self.action = .load_world;
        }
    }

    fn actionCreateWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
        const name = self.getInputName();
        if (name.len > 0) {
            self.action = .create_world;
        }
    }

    fn actionDeleteWorld(ctx: ?*anyopaque) void {
        const self = getSelf(ctx);
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

    fn getSelf(ctx: ?*anyopaque) *MenuController {
        return @ptrCast(@alignCast(ctx.?));
    }
};
