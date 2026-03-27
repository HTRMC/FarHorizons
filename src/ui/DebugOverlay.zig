const std = @import("std");
const GameState = @import("../world/GameState.zig");
const ChunkStreamer = GameState.ChunkStreamer;
const WorldState = @import("../world/WorldState.zig");
const BlockState = WorldState.BlockState;
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;
const Raycast = @import("../world/Raycast.zig");
const world_renderer_mod = @import("../renderer/vulkan/WorldRenderer.zig");
const WorldRenderer = world_renderer_mod.WorldRenderer;
const GpuAllocator = @import("../allocators/GpuAllocator.zig").GpuAllocator;

pub const SCREEN_F3: u8 = 0x01;
pub const SCREEN_F4: u8 = 0x02;
pub const SCREEN_F5: u8 = 0x04;

const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
const LINE_HEIGHT: f32 = 20.0;
const RIGHT_MARGIN: f32 = 10.0;

pub fn draw(text: *TextRenderer, game_state: *GameState, wr: *const WorldRenderer, gpu_alloc: *const GpuAllocator) void {
    if (!game_state.show_ui) return;

    if (game_state.debug_screens == 0) return;

    var y: f32 = 10.0;

    if (game_state.debug_screens & SCREEN_F3 != 0) {
        y = drawF3(text, game_state, y);
    }
    if (game_state.debug_screens & SCREEN_F4 != 0) {
        y = drawF4(text, game_state, wr, gpu_alloc, y);
    }
    if (game_state.debug_screens & SCREEN_F5 != 0) {
        drawF5(text, game_state);
    }
}

fn drawF3(text: *TextRenderer, game_state: *GameState, start_y: f32) f32 {
    var buf: [256]u8 = undefined;
    var y = start_y;
    const x: f32 = 10.0;

    text.drawText(x, y, "FarHorizons", white);
    y += LINE_HEIGHT;

    const ft = game_state.frame_timing;
    const fps_text = std.fmt.bufPrint(&buf, "FPS: {d:.0} ({d:.1}ms)", .{ ft.smooth_fps, ft.smooth_frame_ms }) catch "FPS: ?";
    text.drawText(x, y, fps_text, yellow);
    y += LINE_HEIGHT;

    const timing_text = std.fmt.bufPrint(&buf, "Update: {d:.1}ms  Render: {d:.1}ms  Frame: {d:.1}ms", .{
        ft.smooth_update_ms, ft.smooth_render_ms, ft.smooth_frame_ms,
    }) catch "Timing: ?";
    text.drawText(x, y, timing_text, yellow);
    y += LINE_HEIGHT;

    const pos = game_state.camera.position;
    const xyz_text = std.fmt.bufPrint(&buf, "XYZ: {d:.2} / {d:.2} / {d:.2}", .{ pos.x, pos.y, pos.z }) catch "XYZ: ?";
    text.drawText(x, y, xyz_text, yellow);
    y += LINE_HEIGHT;

    const vel = game_state.entities.vel[GameState.Entity.PLAYER];
    const vel_text = std.fmt.bufPrint(&buf, "Velocity: {d:.2} / {d:.2} / {d:.2}", .{ vel[0], vel[1], vel[2] }) catch "Velocity: ?";
    text.drawText(x, y, vel_text, yellow);
    y += LINE_HEIGHT;

    const yaw_deg = game_state.camera.yaw.value;
    const pitch_deg = game_state.camera.pitch.value;
    const facing = yawFacing(game_state.camera.yaw.value);
    const ang_text = std.fmt.bufPrint(&buf, "Facing: {s}  Yaw: {d:.2}  Pitch: {d:.2}", .{ facing, yaw_deg, pitch_deg }) catch "Facing: ?";
    text.drawText(x, y, ang_text, yellow);
    y += LINE_HEIGHT;

    const mode_text: []const u8 = switch (game_state.mode) {
        .flying => "Mode: Flying",
        .walking => "Mode: Walking",
    };
    text.drawText(x, y, mode_text, yellow);
    y += LINE_HEIGHT;

    const ground_text: []const u8 = if (game_state.entities.flags[GameState.Entity.PLAYER].on_ground) "On Ground: true" else "On Ground: false";
    text.drawText(x, y, ground_text, yellow);
    y += LINE_HEIGHT;

    if (game_state.hit_result) |hit| {
        const block = game_state.chunk_map.getBlock(hit.block_pos);
        const block_name = GameState.blockName(block);
        const face_name = dirName(hit.direction);
        const target_text = std.fmt.bufPrint(&buf, "Target: {s} @ ({d}, {d}, {d}) [{s}]", .{
            block_name, hit.block_pos.x, hit.block_pos.y, hit.block_pos.z, face_name,
        }) catch "Target: ?";
        text.drawText(x, y, target_text, yellow);
    } else {
        text.drawText(x, y, "Target: none", yellow);
    }
    y += LINE_HEIGHT;

    const sel_stack = game_state.playerInv().hotbar[game_state.inv.selected_slot];
    const sel_name = GameState.itemName(sel_stack.block);
    const sel_text = std.fmt.bufPrint(&buf, "Selected: [{d}] {s} x{d}", .{ game_state.inv.selected_slot + 1, sel_name, sel_stack.count }) catch "Selected: ?";
    text.drawText(x, y, sel_text, yellow);
    y += LINE_HEIGHT;

    return y;
}

fn drawF4(text: *TextRenderer, game_state: *GameState, wr: *const WorldRenderer, gpu_alloc: *const GpuAllocator, start_y: f32) f32 {
    var buf: [128]u8 = undefined;
    var y = start_y;
    const x: f32 = 10.0;

    y += LINE_HEIGHT * 0.5;
    text.drawText(x, y, "Renderer", white);
    y += LINE_HEIGHT;

    const chunks_loaded = wr.chunk_slot_map.count();
    const total_slots = world_renderer_mod.TOTAL_RENDER_CHUNKS;
    const chunks_text = std.fmt.bufPrint(&buf, "Chunks: {d} / {d} slots", .{ chunks_loaded, total_slots }) catch "Chunks: ?";
    text.drawText(x, y, chunks_text, yellow);
    y += LINE_HEIGHT;

    const queue_depth: u32 = if (game_state.streaming.pool) |pool| pool.loadQueueDepth() else 0;
    const rd = ChunkStreamer.RENDER_DISTANCE;
    const stream_text = std.fmt.bufPrint(&buf, "Streamer: {d} queued, RD={d}", .{ queue_depth, rd }) catch "Streamer: ?";
    text.drawText(x, y, stream_text, yellow);
    y += LINE_HEIGHT;

    const dc_text = std.fmt.bufPrint(&buf, "Active Chunks: {d}", .{wr.active_slot_counts[0]}) catch "Active Chunks: ?";
    text.drawText(x, y, dc_text, yellow);
    y += LINE_HEIGHT;

    const dirty_text = std.fmt.bufPrint(&buf, "Dirty Chunks: {d}", .{game_state.dirty_chunks.count()}) catch "Dirty Chunks: ?";
    text.drawText(x, y, dirty_text, yellow);
    y += LINE_HEIGHT;

    const overdraw_text: []const u8 = if (game_state.overdraw_mode) "Overdraw: on" else "Overdraw: off";
    text.drawText(x, y, overdraw_text, yellow);
    y += LINE_HEIGHT;

    const dbg_cam_text: []const u8 = if (game_state.debug_camera_active) "Debug Camera: on" else "Debug Camera: off";
    text.drawText(x, y, dbg_cam_text, yellow);
    y += LINE_HEIGHT;

    // GPU Memory
    y += LINE_HEIGHT * 0.5;
    text.drawText(x, y, "GPU Memory", white);
    y += LINE_HEIGHT;

    const mb = 1024.0 * 1024.0;
    const pools = [_]struct { name: []const u8, pool: *const @import("../allocators/GpuMemoryPool.zig").GpuMemoryPool }{
        .{ .name = "Device Local", .pool = gpu_alloc.device_local_pool },
        .{ .name = "Host Visible", .pool = gpu_alloc.host_visible_pool },
        .{ .name = "Staging", .pool = gpu_alloc.staging_pool },
    };

    var total_size: u64 = 0;
    var total_used: u64 = 0;
    for (pools) |p| {
        const size = p.pool.size;
        const free: u64 = p.pool.totalFree();
        const used = size - free;
        total_size += size;
        total_used += used;
        const pool_text = std.fmt.bufPrint(&buf, "  {s}: {d:.1} / {d:.1} MB", .{
            p.name,
            @as(f64, @floatFromInt(used)) / mb,
            @as(f64, @floatFromInt(size)) / mb,
        }) catch "  Pool: ?";
        text.drawText(x, y, pool_text, yellow);
        y += LINE_HEIGHT;
    }

    const total_text = std.fmt.bufPrint(&buf, "  Total: {d:.1} / {d:.1} MB", .{
        @as(f64, @floatFromInt(total_used)) / mb,
        @as(f64, @floatFromInt(total_size)) / mb,
    }) catch "  Total: ?";
    text.drawText(x, y, total_text, yellow);
    y += LINE_HEIGHT;

    // Buffer usage
    y += LINE_HEIGHT * 0.5;
    text.drawText(x, y, "Buffers", white);
    y += LINE_HEIGHT;

    const face_cap = world_renderer_mod.INITIAL_FACE_CAPACITY;
    const face_free = wr.face_tlsf.totalFree();
    const face_used = face_cap - face_free;
    const face_text = std.fmt.bufPrint(&buf, "  Faces: {d} / {d}", .{ face_used, face_cap }) catch "  Faces: ?";
    text.drawText(x, y, face_text, yellow);
    y += LINE_HEIGHT;

    const light_cap = world_renderer_mod.INITIAL_LIGHT_CAPACITY;
    const light_free = wr.light_tlsf.totalFree();
    const light_used = light_cap - light_free;
    const light_text = std.fmt.bufPrint(&buf, "  Lights: {d} / {d}", .{ light_used, light_cap }) catch "  Lights: ?";
    text.drawText(x, y, light_text, yellow);
    y += LINE_HEIGHT;

    return y;
}

fn drawTextRight(text: *TextRenderer, y: f32, str: []const u8, color: [4]f32) void {
    const w = text.measureText(str);
    text.drawText(text.screen_width - w - RIGHT_MARGIN, y, str, color);
}

fn drawF5(text: *TextRenderer, game_state: *GameState) void {
    var buf: [128]u8 = undefined;
    var y: f32 = 10.0;

    drawTextRight(text, y, "World", white);
    y += LINE_HEIGHT;

    const chunk_count = game_state.chunk_map.count();
    const chunks_text = std.fmt.bufPrint(&buf, "Loaded Chunks: {d} ({d}^3 blocks each)", .{
        chunk_count, WorldState.CHUNK_SIZE,
    }) catch "Chunks: ?";
    drawTextRight(text, y, chunks_text, yellow);
    y += LINE_HEIGHT;

    const rd = ChunkStreamer.RENDER_DISTANCE;
    const ud = ChunkStreamer.UNLOAD_DISTANCE;
    const rd_text = std.fmt.bufPrint(&buf, "Render Distance: {d}  Unload: {d}", .{ rd, ud }) catch "RD: ?";
    drawTextRight(text, y, rd_text, yellow);
    y += LINE_HEIGHT;

    const pos = game_state.camera.position;
    const player_key = WorldState.WorldBlockPos.init(
        @intFromFloat(@floor(pos.x)),
        @intFromFloat(@floor(pos.y)),
        @intFromFloat(@floor(pos.z)),
    ).toChunkKey();
    const ck_text = std.fmt.bufPrint(&buf, "Player Chunk: ({d}, {d}, {d})", .{
        player_key.cx, player_key.cy, player_key.cz,
    }) catch "Player Chunk: ?";
    drawTextRight(text, y, ck_text, yellow);
    y += LINE_HEIGHT;
}

fn yawFacing(yaw: f32) []const u8 {
    // Normalize to [0, 360)
    const normalized = @mod(yaw, 360.0);
    // yaw=0 → -Z (north), increases counterclockwise: N → W → S → E
    if (normalized < 45.0 or normalized >= 315.0)
        return "North (-Z)"
    else if (normalized < 135.0)
        return "West (-X)"
    else if (normalized < 225.0)
        return "South (+Z)"
    else
        return "East (+X)";
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
