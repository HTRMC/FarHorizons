const std = @import("std");
const UiManager = @import("UiManager.zig").UiManager;
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const ActionRegistry = @import("ActionRegistry.zig").ActionRegistry;
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

    // World list data
    world_names: [MAX_WORLDS][MAX_NAME_LEN]u8 = undefined,
    world_name_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
    world_count: u8 = 0,
    selection: u8 = 0,

    // Screen tracking
    title_screen_loaded: bool = false,
    singleplayer_screen_loaded: bool = false,
    pause_screen_loaded: bool = false,

    // Cached widget IDs (title screen)
    coming_soon_modal_id: WidgetId = NULL_WIDGET,

    // Cached widget IDs (singleplayer screen)
    world_list_id: WidgetId = NULL_WIDGET,
    no_worlds_label_id: WidgetId = NULL_WIDGET,
    delete_confirm_id: WidgetId = NULL_WIDGET,
    delete_label_id: WidgetId = NULL_WIDGET,
    world_name_input_id: WidgetId = NULL_WIDGET,

    /// Create a MenuController and load the title screen.
    /// Caller MUST call `registerActions()` after storing the result at its
    /// final address — the action callbacks capture a pointer to `self`.
    pub fn init(ui_manager: *UiManager, allocator: std.mem.Allocator) MenuController {
        var self = MenuController{
            .ui_manager = ui_manager,
            .allocator = allocator,
        };

        // Load title screen
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
        if (self.ui_manager.screen_count < 2) return null;
        if (!self.ui_manager.screens[1].active) return null;
        return &self.ui_manager.screens[1].tree;
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

        // Read worlds from disk
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

        // Update the list_view widget
        self.populateWorldListWidget();
    }

    fn populateWorldListWidget(self: *MenuController) void {
        const tree = self.singleplayerTree() orelse return;

        // Update list_view item_count
        if (self.world_list_id != NULL_WIDGET) {
            if (tree.getData(self.world_list_id)) |data| {
                data.list_view.item_count = self.world_count;
                data.list_view.selected_index = self.selection;
                data.list_view.scroll_offset = 0;
            }

            // Clear existing children and add label for each world
            tree.clearChildren(self.world_list_id);
            for (0..self.world_count) |i| {
                const name = self.world_names[i][0..self.world_name_lens[i]];
                const label_id = tree.addWidget(.label, self.world_list_id) orelse break;
                if (tree.getWidget(label_id)) |w| {
                    w.width = .fill;
                    w.height = .{ .px = 28 };
                    w.padding = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 };
                }
                if (tree.getData(label_id)) |data| {
                    data.label.setText(name);
                    data.label.color = Widget.Color.white;
                }
            }
        }

        // Toggle no-worlds label visibility
        if (self.no_worlds_label_id != NULL_WIDGET) {
            if (tree.getWidget(self.no_worlds_label_id)) |w| {
                w.visible = (self.world_count == 0);
            }
        }

        // Hide delete confirmation
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
        // Remove singleplayer screen if loaded
        if (self.singleplayer_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        // Remove pause screen if still on stack
        if (self.pause_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.pause_screen_loaded = false;
        }
        // If title screen was removed, reload it
        if (!self.title_screen_loaded or self.ui_manager.screen_count == 0) {
            if (self.ui_manager.loadScreenFromFile("title_menu.xml", self.allocator)) {
                self.title_screen_loaded = true;
                self.cacheTitleWidgetIds();
            }
        }
        self.app_state = .title_menu;
    }

    /// Hide the title screen (when entering gameplay).
    pub fn hideTitleMenu(self: *MenuController) void {
        // Remove singleplayer screen first if loaded
        if (self.singleplayer_screen_loaded) {
            self.ui_manager.removeTopScreen();
            self.singleplayer_screen_loaded = false;
            self.resetSingleplayerWidgetIds();
        }
        if (self.title_screen_loaded and self.ui_manager.screen_count > 0) {
            self.ui_manager.removeTopScreen();
            self.title_screen_loaded = false;
        }
    }

    pub fn getSelectedWorldName(self: *const MenuController) []const u8 {
        if (self.world_count == 0) return "";
        const sel = self.selection;
        if (sel >= self.world_count) return "";
        return self.world_names[sel][0..self.world_name_lens[sel]];
    }

    pub fn getInputName(self: *const MenuController) []const u8 {
        const tree: *const WidgetTree = if (self.singleplayer_screen_loaded and self.ui_manager.screen_count > 1)
            &self.ui_manager.screens[1].tree
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

    // ── Action callbacks ──

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

        // Show delete confirmation panel
        const tree = self.singleplayerTree() orelse return;
        if (self.delete_confirm_id != NULL_WIDGET) {
            if (tree.getWidget(self.delete_confirm_id)) |w| {
                w.visible = true;
            }
        }
        // Update label text
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
        // Hide confirm panel
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
