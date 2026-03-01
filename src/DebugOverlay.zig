const std = @import("std");
const GameState = @import("GameState.zig");
const WorldState = @import("world/WorldState.zig");
const TextRenderer = @import("renderer/vulkan/TextRenderer.zig").TextRenderer;
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");

pub const SCREEN_F3: u8 = 0x01;
pub const SCREEN_F4: u8 = 0x02;
pub const SCREEN_F5: u8 = 0x04;
pub const SCREEN_F6: u8 = 0x08;
pub const SCREEN_F7: u8 = 0x10;

const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
const LINE_HEIGHT: f32 = 20.0;

pub fn draw(text: *TextRenderer, gs: *GameState, draw_count: u32) void {
    if (gs.debug_screens == 0) {
        text.drawText(10.0, 10.0, "FarHorizons", white);
        return;
    }

    var col_x: f32 = 10.0;

    if (gs.debug_screens & SCREEN_F3 != 0) {
        col_x = drawF3(text, gs, col_x);
    }
    if (gs.debug_screens & SCREEN_F4 != 0) {
        col_x = drawF4(text, gs, draw_count, col_x);
    }
    if (gs.debug_screens & SCREEN_F5 != 0) {
        col_x = drawF5(text, gs, col_x);
    }
    if (gs.debug_screens & SCREEN_F6 != 0) {
        col_x = drawF6(text, gs, col_x);
    }
    if (gs.debug_screens & SCREEN_F7 != 0) {
        _ = drawF7(text, col_x);
    }
}

fn drawF3(text: *TextRenderer, gs: *GameState, start_x: f32) f32 {
    var buf: [256]u8 = undefined;
    var y: f32 = 10.0;
    const x = start_x;

    text.drawText(x, y, "FarHorizons", white);
    y += LINE_HEIGHT;

    const fps: f32 = if (gs.delta_time > 0) 1.0 / gs.delta_time else 0;
    const ms = gs.delta_time * 1000.0;
    const fps_text = std.fmt.bufPrint(&buf, "FPS: {d:.0} ({d:.1}ms)", .{ fps, ms }) catch "FPS: ?";
    text.drawText(x, y, fps_text, yellow);
    y += LINE_HEIGHT;

    const pos = gs.camera.position;
    const xyz_text = std.fmt.bufPrint(&buf, "XYZ: {d:.2} / {d:.2} / {d:.2}", .{ pos.x, pos.y, pos.z }) catch "XYZ: ?";
    text.drawText(x, y, xyz_text, yellow);
    y += LINE_HEIGHT;

    const vel = gs.entity_vel;
    const vel_text = std.fmt.bufPrint(&buf, "Velocity: {d:.2} / {d:.2} / {d:.2}", .{ vel[0], vel[1], vel[2] }) catch "Velocity: ?";
    text.drawText(x, y, vel_text, yellow);
    y += LINE_HEIGHT;

    const deg = 180.0 / std.math.pi;
    const yaw_deg = gs.camera.yaw * deg;
    const pitch_deg = gs.camera.pitch * deg;
    const ang_text = std.fmt.bufPrint(&buf, "Yaw: {d:.2}  Pitch: {d:.2}", .{ yaw_deg, pitch_deg }) catch "Yaw: ?";
    text.drawText(x, y, ang_text, yellow);
    y += LINE_HEIGHT;

    const mode_text: []const u8 = switch (gs.mode) {
        .flying => "Mode: Flying",
        .walking => "Mode: Walking",
    };
    text.drawText(x, y, mode_text, yellow);
    y += LINE_HEIGHT;

    const ground_text: []const u8 = if (gs.entity_on_ground) "On Ground: true" else "On Ground: false";
    text.drawText(x, y, ground_text, yellow);
    y += LINE_HEIGHT;

    if (gs.hit_result) |hit| {
        const block = WorldState.getBlock(gs.world, hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
        const block_name = GameState.blockName(block);
        const face_name = dirName(hit.direction);
        const target_text = std.fmt.bufPrint(&buf, "Target: {s} @ ({d}, {d}, {d}) [{s}]", .{
            block_name, hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], face_name,
        }) catch "Target: ?";
        text.drawText(x, y, target_text, yellow);
    } else {
        text.drawText(x, y, "Target: none", yellow);
    }
    y += LINE_HEIGHT;

    const sel_name = GameState.blockName(gs.hotbar[gs.selected_slot]);
    const sel_text = std.fmt.bufPrint(&buf, "Selected: [{d}] {s}", .{ gs.selected_slot + 1, sel_name }) catch "Selected: ?";
    text.drawText(x, y, sel_text, yellow);

    return x + 280.0;
}

fn drawF4(text: *TextRenderer, gs: *GameState, draw_count: u32, start_x: f32) f32 {
    var buf: [128]u8 = undefined;
    var y: f32 = 10.0;
    const x = start_x;

    text.drawText(x, y, "Renderer", white);
    y += LINE_HEIGHT;

    const lod_text = std.fmt.bufPrint(&buf, "LOD: {d}", .{gs.current_lod}) catch "LOD: ?";
    text.drawText(x, y, lod_text, yellow);
    y += LINE_HEIGHT;

    const dc_text = std.fmt.bufPrint(&buf, "Draw Calls: {d}", .{draw_count}) catch "Draw Calls: ?";
    text.drawText(x, y, dc_text, yellow);
    y += LINE_HEIGHT;

    const dirty_text = std.fmt.bufPrint(&buf, "Dirty Chunks: {d}/{d}", .{ gs.dirty_chunks.count, WorldState.TOTAL_WORLD_CHUNKS }) catch "Dirty Chunks: ?";
    text.drawText(x, y, dirty_text, yellow);
    y += LINE_HEIGHT;

    const overdraw_text: []const u8 = if (gs.overdraw_mode) "Overdraw: on" else "Overdraw: off";
    text.drawText(x, y, overdraw_text, yellow);
    y += LINE_HEIGHT;

    const dbg_cam_text: []const u8 = if (gs.debug_camera_active) "Debug Camera: on" else "Debug Camera: off";
    text.drawText(x, y, dbg_cam_text, yellow);

    return x + 220.0;
}

fn drawF5(text: *TextRenderer, gs: *GameState, start_x: f32) f32 {
    var buf: [128]u8 = undefined;
    var y: f32 = 10.0;
    const x = start_x;

    text.drawText(x, y, "World", white);
    y += LINE_HEIGHT;

    const chunks_text = std.fmt.bufPrint(&buf, "Chunks: {d}x{d}x{d} ({d}^3 blocks)", .{
        WorldState.WORLD_CHUNKS_X, WorldState.WORLD_CHUNKS_Y, WorldState.WORLD_CHUNKS_Z, WorldState.CHUNK_SIZE,
    }) catch "Chunks: ?";
    text.drawText(x, y, chunks_text, yellow);
    y += LINE_HEIGHT;

    const size_text = std.fmt.bufPrint(&buf, "World Size: {d}x{d}x{d}", .{
        WorldState.WORLD_SIZE_X, WorldState.WORLD_SIZE_Y, WorldState.WORLD_SIZE_Z,
    }) catch "World Size: ?";
    text.drawText(x, y, size_text, yellow);
    y += LINE_HEIGHT;

    const lod_text = std.fmt.bufPrint(&buf, "LOD Levels: {d}", .{GameState.MAX_LOD}) catch "LOD Levels: ?";
    text.drawText(x, y, lod_text, yellow);
    y += LINE_HEIGHT;

    const cur_lod_text = std.fmt.bufPrint(&buf, "Current LOD: {d}", .{gs.current_lod}) catch "Current LOD: ?";
    text.drawText(x, y, cur_lod_text, yellow);
    y += LINE_HEIGHT;

    const voxel_size: u32 = @as(u32, 1) << @intCast(gs.current_lod);
    const vs_text = std.fmt.bufPrint(&buf, "Voxel Size: {d}", .{voxel_size}) catch "Voxel Size: ?";
    text.drawText(x, y, vs_text, yellow);

    return x + 260.0;
}

fn drawF6(text: *TextRenderer, gs: *GameState, start_x: f32) f32 {
    var y: f32 = 10.0;
    const x = start_x;

    text.drawText(x, y, "Storage", white);
    y += LINE_HEIGHT;

    if (gs.storage) |s| {
        text.drawText(x, y, "Status: active", yellow);
        y += LINE_HEIGHT;

        var buf: [256]u8 = undefined;
        const path_text = std.fmt.bufPrint(&buf, "World Path: {s}", .{s.world_dir}) catch "World Path: ?";
        text.drawText(x, y, path_text, yellow);
    } else {
        text.drawText(x, y, "Status: disabled", yellow);
    }

    return x + 220.0;
}

fn drawF7(text: *TextRenderer, start_x: f32) f32 {
    var y: f32 = 10.0;
    const x = start_x;

    text.drawText(x, y, "Controls", white);
    y += LINE_HEIGHT;

    const lines = [_][]const u8{
        "WASD - Move",
        "Space - Jump / Fly Up",
        "Shift - Fly Down",
        "P - Debug Camera",
        "Shift+F4 - Overdraw",
        "Ctrl+1-5 - LOD Switch",
        "1-9 - Hotbar Slot",
        "Dbl Space - Toggle Fly/Walk",
        "ESC - Pause Menu",
    };

    for (lines) |line| {
        text.drawText(x, y, line, yellow);
        y += LINE_HEIGHT;
    }

    return x + 250.0;
}

fn dirName(dir: Raycast.Direction) []const u8 {
    return switch (dir) {
        .west => "-X",
        .east => "+X",
        .down => "-Y",
        .up => "+Y",
        .north => "-Z",
        .south => "+Z",
    };
}
