const std = @import("std");
const glfw = @import("../platform/glfw.zig");
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;
const app_config = @import("../app_config.zig");

pub const Menu = struct {
    app_state: AppState = .title_menu,
    world_names: [MAX_WORLDS][MAX_NAME_LEN]u8 = undefined,
    world_name_lens: [MAX_WORLDS]u8 = .{0} ** MAX_WORLDS,
    world_count: u8 = 0,
    selection: u8 = 0,
    input_active: bool = false,
    input_skip_char: bool = false,
    input_buf: [MAX_NAME_LEN]u8 = .{0} ** MAX_NAME_LEN,
    input_len: u8 = 0,
    delete_confirm: bool = false,
    pause_selection: u8 = 0,
    action: ?Action = null,

    pub const MAX_WORLDS: u8 = 32;
    pub const MAX_NAME_LEN: u8 = 32;

    pub const AppState = enum { title_menu, playing, pause_menu };
    pub const Action = enum { load_world, create_world, delete_world, resume_game, return_to_title, quit };

    pub fn init() Menu {
        return .{};
    }

    pub fn refreshWorldList(self: *Menu, allocator: std.mem.Allocator) void {
        // Free previous names (they were duped from allocator)
        // Actually we copy into fixed buffers, so nothing to free.
        self.world_count = 0;
        self.selection = 0;

        var name_slices: [MAX_WORLDS][]const u8 = undefined;
        const count = app_config.listWorlds(allocator, &name_slices) catch 0;

        for (0..count) |i| {
            const name = name_slices[i];
            const len: u8 = @intCast(@min(name.len, MAX_NAME_LEN));
            @memcpy(self.world_names[i][0..len], name[0..len]);
            self.world_name_lens[i] = len;
            allocator.free(name);
        }
        self.world_count = count;
    }

    pub fn handleKey(self: *Menu, key: c_int, action: c_int) void {
        if (action != glfw.GLFW_PRESS and action != glfw.GLFW_REPEAT) return;

        switch (self.app_state) {
            .title_menu => self.handleTitleKey(key),
            .pause_menu => self.handlePauseKey(key),
            .playing => {},
        }
    }

    fn handleTitleKey(self: *Menu, key: c_int) void {
        if (self.delete_confirm) {
            if (key == glfw.GLFW_KEY_Y) {
                self.action = .delete_world;
                self.delete_confirm = false;
            } else {
                self.delete_confirm = false;
            }
            return;
        }

        if (self.input_active) {
            if (key == glfw.GLFW_KEY_ENTER) {
                if (self.input_len > 0) {
                    self.action = .create_world;
                }
                self.input_active = false;
            } else if (key == glfw.GLFW_KEY_ESCAPE) {
                self.input_active = false;
                self.input_len = 0;
            } else if (key == glfw.GLFW_KEY_BACKSPACE) {
                if (self.input_len > 0) self.input_len -= 1;
            }
            return;
        }

        if (key == glfw.GLFW_KEY_UP) {
            if (self.selection > 0) self.selection -= 1;
        } else if (key == glfw.GLFW_KEY_DOWN) {
            if (self.world_count > 0 and self.selection < self.world_count - 1) self.selection += 1;
        } else if (key == glfw.GLFW_KEY_ENTER) {
            if (self.world_count > 0) self.action = .load_world;
        } else if (key == glfw.GLFW_KEY_N) {
            self.input_active = true;
            self.input_skip_char = true;
            self.input_len = 0;
        } else if (key == glfw.GLFW_KEY_DELETE) {
            if (self.world_count > 0) self.delete_confirm = true;
        } else if (key == glfw.GLFW_KEY_ESCAPE) {
            self.action = .quit;
        }
    }

    fn handlePauseKey(self: *Menu, key: c_int) void {
        if (key == glfw.GLFW_KEY_UP) {
            if (self.pause_selection > 0) self.pause_selection -= 1;
        } else if (key == glfw.GLFW_KEY_DOWN) {
            if (self.pause_selection < 1) self.pause_selection += 1;
        } else if (key == glfw.GLFW_KEY_ENTER) {
            if (self.pause_selection == 0) {
                self.action = .resume_game;
            } else {
                self.action = .return_to_title;
            }
        } else if (key == glfw.GLFW_KEY_ESCAPE) {
            self.action = .resume_game;
        }
    }

    pub fn handleChar(self: *Menu, codepoint: u32) void {
        if (!self.input_active) return;
        if (self.input_skip_char) {
            self.input_skip_char = false;
            return;
        }
        if (self.input_len >= MAX_NAME_LEN) return;

        // Only accept [a-zA-Z0-9_-]
        const ch: u8 = if (codepoint <= 127) @intCast(codepoint) else return;
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ' ') {
            self.input_buf[self.input_len] = ch;
            self.input_len += 1;
        }
    }

    pub fn getSelectedWorldName(self: *const Menu) []const u8 {
        if (self.world_count == 0) return "";
        return self.world_names[self.selection][0..self.world_name_lens[self.selection]];
    }

    pub fn getInputName(self: *const Menu) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn draw(self: *const Menu, tr: *TextRenderer, screen_w: f32, screen_h: f32) void {
        switch (self.app_state) {
            .title_menu => self.drawTitleMenu(tr, screen_w, screen_h),
            .pause_menu => self.drawPauseMenu(tr, screen_w, screen_h),
            .playing => {},
        }
    }

    fn drawTitleMenu(self: *const Menu, tr: *TextRenderer, screen_w: f32, screen_h: f32) void {
        _ = screen_h;
        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
        const gray = [4]f32{ 0.6, 0.6, 0.6, 1.0 };
        const red = [4]f32{ 1.0, 0.3, 0.3, 1.0 };

        // Title
        const title = "FARHORIZONS";
        const title_w = tr.measureText(title);
        tr.drawText((screen_w - title_w) / 2.0, 60.0, title, white);

        // World list
        const list_y: f32 = 120.0;
        const line_height: f32 = 24.0;

        if (self.world_count == 0) {
            const no_worlds = "No worlds yet. Press [N] to create one.";
            const nw_w = tr.measureText(no_worlds);
            tr.drawText((screen_w - nw_w) / 2.0, list_y, no_worlds, gray);
        } else {
            for (0..self.world_count) |i| {
                const name = self.world_names[i][0..self.world_name_lens[i]];
                const y = list_y + @as(f32, @floatFromInt(i)) * line_height;
                const is_selected = i == self.selection;

                if (is_selected) {
                    const prefix = "> ";
                    const full_w = tr.measureText(prefix) + tr.measureText(name);
                    const x = (screen_w - full_w) / 2.0;
                    tr.drawText(x, y, prefix, yellow);
                    tr.drawText(x + tr.measureText(prefix), y, name, yellow);
                } else {
                    const name_w = tr.measureText(name);
                    tr.drawText((screen_w - name_w) / 2.0, y, name, white);
                }
            }
        }

        // Delete confirmation
        if (self.delete_confirm and self.world_count > 0) {
            const del_name = self.world_names[self.selection][0..self.world_name_lens[self.selection]];
            var del_buf: [80]u8 = undefined;
            const del_text = std.fmt.bufPrint(&del_buf, "Delete \"{s}\"?  [Y] Yes  [N] No", .{del_name}) catch "Delete? [Y/N]";
            const del_w = tr.measureText(del_text);
            const del_y = list_y + @as(f32, @floatFromInt(self.world_count)) * line_height + 20.0;
            tr.drawText((screen_w - del_w) / 2.0, del_y, del_text, red);
            return;
        }

        // Input prompt
        if (self.input_active) {
            const input_y = list_y + @as(f32, @floatFromInt(self.world_count)) * line_height + 20.0;
            const label = "Name: ";
            const input_text = self.input_buf[0..self.input_len];
            const cursor = "_";
            const full_w = tr.measureText(label) + tr.measureText(input_text) + tr.measureText(cursor);
            const x = (screen_w - full_w) / 2.0;
            tr.drawText(x, input_y, label, gray);
            tr.drawText(x + tr.measureText(label), input_y, input_text, white);
            tr.drawText(x + tr.measureText(label) + tr.measureText(input_text), input_y, cursor, yellow);
            return;
        }

        // Footer
        const footer_y = list_y + @as(f32, @floatFromInt(@max(@as(u8, 1), self.world_count))) * line_height + 30.0;
        const footer = "[Enter] Play   [N] New   [Del] Delete   [Esc] Quit";
        const footer_w = tr.measureText(footer);
        tr.drawText((screen_w - footer_w) / 2.0, footer_y, footer, gray);
    }

    fn drawPauseMenu(self: *const Menu, tr: *TextRenderer, screen_w: f32, screen_h: f32) void {
        _ = screen_h;
        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
        const gray = [4]f32{ 0.6, 0.6, 0.6, 1.0 };

        // Title
        const title = "--- Paused ---";
        const title_w = tr.measureText(title);
        tr.drawText((screen_w - title_w) / 2.0, 120.0, title, gray);

        const items = [_][]const u8{ "Resume", "Return to Title" };
        const base_y: f32 = 170.0;
        const line_height: f32 = 24.0;

        for (items, 0..) |item, i| {
            const y = base_y + @as(f32, @floatFromInt(i)) * line_height;
            const is_selected = i == self.pause_selection;

            if (is_selected) {
                const prefix = "> ";
                const full_w = tr.measureText(prefix) + tr.measureText(item);
                const x = (screen_w - full_w) / 2.0;
                tr.drawText(x, y, prefix, yellow);
                tr.drawText(x + tr.measureText(prefix), y, item, yellow);
            } else {
                const item_w = tr.measureText(item);
                tr.drawText((screen_w - item_w) / 2.0, y, item, white);
            }
        }
    }
};
