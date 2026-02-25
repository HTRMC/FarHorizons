const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const Color = Widget.Color;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const Layout = @import("Layout.zig");
const WidgetOps = @import("WidgetOps.zig");
const UiRenderer = @import("../renderer/vulkan/UiRenderer.zig").UiRenderer;
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;

const MAX_SCREEN_STACK = 4;

pub const Screen = struct {
    tree: WidgetTree = .{},
    passthrough: bool = false,
    active: bool = false,
};

pub const UiManager = struct {
    screens: [MAX_SCREEN_STACK]Screen = [_]Screen{.{}} ** MAX_SCREEN_STACK,
    screen_count: u8 = 0,
    screen_width: f32 = 800.0,
    screen_height: f32 = 600.0,

    /// Push a new screen onto the stack. Returns the screen index for building.
    pub fn pushScreen(self: *UiManager) ?*Screen {
        if (self.screen_count >= MAX_SCREEN_STACK) return null;
        const idx = self.screen_count;
        self.screen_count += 1;
        self.screens[idx] = .{ .active = true };
        return &self.screens[idx];
    }

    /// Pop the top screen from the stack.
    pub fn popScreen(self: *UiManager) void {
        if (self.screen_count == 0) return;
        self.screen_count -= 1;
        self.screens[self.screen_count].active = false;
        self.screens[self.screen_count].tree.clear();
    }

    /// Get the top screen (if any).
    pub fn topScreen(self: *UiManager) ?*Screen {
        if (self.screen_count == 0) return null;
        return &self.screens[self.screen_count - 1];
    }

    pub fn updateScreenSize(self: *UiManager, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    /// Run layout on all active screens.
    pub fn layout(self: *UiManager, text_renderer: *const TextRenderer) void {
        for (0..self.screen_count) |i| {
            if (self.screens[i].active) {
                Layout.layoutTree(&self.screens[i].tree, self.screen_width, self.screen_height, text_renderer);
            }
        }
    }

    /// Draw all active screens (bottom to top).
    pub fn draw(self: *UiManager, ui: *UiRenderer, tr: *TextRenderer) void {
        for (0..self.screen_count) |i| {
            const screen = &self.screens[i];
            if (!screen.active) continue;
            if (screen.tree.root != NULL_WIDGET) {
                WidgetOps.drawWidget(&screen.tree, screen.tree.root, ui, tr);
            }
        }
    }

    /// Check if the top screen blocks input passthrough to the game.
    pub fn blocksInput(self: *const UiManager) bool {
        if (self.screen_count == 0) return false;
        return !self.screens[self.screen_count - 1].passthrough;
    }

    /// Build the hardcoded test screen (temporary, will be replaced by XML loading).
    pub fn buildTestScreen(self: *UiManager) void {
        const screen = self.pushScreen() orelse return;
        var tree = &screen.tree;

        // Root panel — centered, semi-transparent dark background
        const root = tree.addWidget(.panel, NULL_WIDGET) orelse return;
        var root_w = tree.getWidget(root).?;
        root_w.width = .{ .px = 320 };
        root_w.height = .auto;
        root_w.background = Color.fromHex(0x1A1A2ECC);
        root_w.padding = Widget.Edges.uniform(16);
        root_w.layout_mode = .flex;
        root_w.flex_direction = .column;
        root_w.cross_align = .center;
        root_w.justify = .center;
        root_w.gap = 8;
        // Anchor root to center of screen
        root_w.anchor_x = .center;
        root_w.anchor_y = .center;

        // We need the root to be positioned by anchor on the implicit screen container.
        // Since root IS the tree root, layout handles it specially.
        // Instead, let's make a real screen-root that uses anchor layout.
        tree.clear();
        const screen_root = tree.addWidget(.panel, NULL_WIDGET) orelse return;
        var sr = tree.getWidget(screen_root).?;
        sr.width = .fill;
        sr.height = .fill;
        sr.layout_mode = .anchor;
        sr.background = Color.transparent;

        // Centered panel
        const panel = tree.addWidget(.panel, screen_root) orelse return;
        var p = tree.getWidget(panel).?;
        p.width = .{ .px = 320 };
        p.height = .auto;
        p.background = Color.fromHex(0x1A1A2ECC);
        p.padding = Widget.Edges.uniform(16);
        p.layout_mode = .flex;
        p.flex_direction = .column;
        p.cross_align = .center;
        p.justify = .center;
        p.gap = 8;
        p.anchor_x = .center;
        p.anchor_y = .center;
        p.border_width = 1;
        p.border_color = Color.fromHex(0x444466FF);

        // Title label
        const title = tree.addWidget(.label, panel) orelse return;
        tree.getWidget(title).?.width = .auto;
        tree.getWidget(title).?.height = .auto;
        var title_data = &tree.getData(title).?.label;
        title_data.setText("UI System Test");
        title_data.color = Color.fromHex(0xFFCC00FF);
        title_data.font_size = 2;

        // Subtitle
        const subtitle = tree.addWidget(.label, panel) orelse return;
        tree.getWidget(subtitle).?.width = .auto;
        tree.getWidget(subtitle).?.height = .auto;
        var sub_data = &tree.getData(subtitle).?.label;
        sub_data.setText("Phase 1 - Foundation");
        sub_data.color = Color.fromHex(0xAAAAAAFF);

        // Button row
        const btn_row = tree.addWidget(.panel, panel) orelse return;
        var br = tree.getWidget(btn_row).?;
        br.layout_mode = .flex;
        br.flex_direction = .row;
        br.gap = 8;
        br.width = .auto;
        br.height = .auto;
        br.cross_align = .center;

        // Button 1
        const btn1 = tree.addWidget(.button, btn_row) orelse return;
        var b1 = tree.getWidget(btn1).?;
        b1.width = .{ .px = 80 };
        b1.height = .{ .px = 28 };
        b1.background = Color.fromHex(0x335588FF);
        var b1d = &tree.getData(btn1).?.button;
        b1d.setText("Play");

        // Button 2
        const btn2 = tree.addWidget(.button, btn_row) orelse return;
        var b2 = tree.getWidget(btn2).?;
        b2.width = .{ .px = 80 };
        b2.height = .{ .px = 28 };
        b2.background = Color.fromHex(0x553333FF);
        var b2d = &tree.getData(btn2).?.button;
        b2d.setText("Quit");

        // Progress bar
        const pb = tree.addWidget(.progress_bar, panel) orelse return;
        var pbw = tree.getWidget(pb).?;
        pbw.width = .fill;
        pbw.height = .{ .px = 12 };
        tree.getData(pb).?.progress_bar.value = 0.65;
        tree.getData(pb).?.progress_bar.fill_color = Color.fromHex(0x44AA44FF);
    }
};
