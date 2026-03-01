const std = @import("std");
const GameState = @import("GameState.zig");
const WorldState = @import("world/WorldState.zig");
const TextRenderer = @import("renderer/vulkan/TextRenderer.zig").TextRenderer;
const Raycast = @import("Raycast.zig");
const world_renderer_mod = @import("renderer/vulkan/WorldRenderer.zig");
const WorldRenderer = world_renderer_mod.WorldRenderer;
const GpuAllocator = @import("allocators/GpuAllocator.zig").GpuAllocator;

pub const SCREEN_F3: u8 = 0x01;
pub const SCREEN_F4: u8 = 0x02;
pub const SCREEN_F5: u8 = 0x04;

const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
const LINE_HEIGHT: f32 = 20.0;
const RIGHT_MARGIN: f32 = 10.0;

pub fn draw(text: *TextRenderer, gs: *GameState, wr: *const WorldRenderer, gpu_alloc: *const GpuAllocator) void {
    if (gs.debug_screens == 0) {
        text.drawText(10.0, 10.0, "FarHorizons", white);
        return;
    }

    var y: f32 = 10.0;

    if (gs.debug_screens & SCREEN_F3 != 0) {
        y = drawF3(text, gs, y);
    }
    if (gs.debug_screens & SCREEN_F4 != 0) {
        y = drawF4(text, gs, wr, gpu_alloc, y);
    }
    if (gs.debug_screens & SCREEN_F5 != 0) {
        drawF5(text, gs);
    }
}

fn drawF3(text: *TextRenderer, gs: *GameState, start_y: f32) f32 {
    var buf: [256]u8 = undefined;
    var y = start_y;
    const x: f32 = 10.0;

    text.drawText(x, y, "FarHorizons", white);
    y += LINE_HEIGHT;

    const fps: f32 = if (gs.delta_time > 0) 1.0 / gs.delta_time else 0;
    const ms = gs.delta_time * 1000.0;
    const fps_text = std.fmt.bufPrint(&buf, "FPS: {d:.0} ({d:.1}ms)", .{ fps, ms }) catch "FPS: ?";
    text.drawText(x, y, fps_text, yellow);
    y += LINE_HEIGHT;

    const ft = gs.frame_timing;
    const timing_text = std.fmt.bufPrint(&buf, "Update: {d:.1}ms  Render: {d:.1}ms  Frame: {d:.1}ms", .{
        ft.update_ms, ft.render_ms, ft.frame_ms,
    }) catch "Timing: ?";
    text.drawText(x, y, timing_text, yellow);
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
    y += LINE_HEIGHT;

    return y;
}

fn drawF4(text: *TextRenderer, gs: *GameState, wr: *const WorldRenderer, gpu_alloc: *const GpuAllocator, start_y: f32) f32 {
    var buf: [128]u8 = undefined;
    var y = start_y;
    const x: f32 = 10.0;

    y += LINE_HEIGHT * 0.5;
    text.drawText(x, y, "Renderer", white);
    y += LINE_HEIGHT;

    const lod_text = std.fmt.bufPrint(&buf, "LOD: {d}", .{gs.current_lod}) catch "LOD: ?";
    text.drawText(x, y, lod_text, yellow);
    y += LINE_HEIGHT;

    const dc_text = std.fmt.bufPrint(&buf, "Draw Calls: {d}", .{wr.draw_count}) catch "Draw Calls: ?";
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
    y += LINE_HEIGHT;

    // GPU Memory
    y += LINE_HEIGHT * 0.5;
    text.drawText(x, y, "GPU Memory", white);
    y += LINE_HEIGHT;

    const mb = 1024.0 * 1024.0;
    const pools = [_]struct { name: []const u8, pool: *const @import("allocators/GpuMemoryPool.zig").GpuMemoryPool }{
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

fn drawF5(text: *TextRenderer, gs: *GameState) void {
    var buf: [128]u8 = undefined;
    var y: f32 = 10.0;

    drawTextRight(text, y, "World", white);
    y += LINE_HEIGHT;

    const chunks_text = std.fmt.bufPrint(&buf, "Chunks: {d}x{d}x{d} ({d}^3 blocks)", .{
        WorldState.WORLD_CHUNKS_X, WorldState.WORLD_CHUNKS_Y, WorldState.WORLD_CHUNKS_Z, WorldState.CHUNK_SIZE,
    }) catch "Chunks: ?";
    drawTextRight(text, y, chunks_text, yellow);
    y += LINE_HEIGHT;

    const size_text = std.fmt.bufPrint(&buf, "World Size: {d}x{d}x{d}", .{
        WorldState.WORLD_SIZE_X, WorldState.WORLD_SIZE_Y, WorldState.WORLD_SIZE_Z,
    }) catch "World Size: ?";
    drawTextRight(text, y, size_text, yellow);
    y += LINE_HEIGHT;

    const lod_text = std.fmt.bufPrint(&buf, "LOD Levels: {d}", .{GameState.MAX_LOD}) catch "LOD Levels: ?";
    drawTextRight(text, y, lod_text, yellow);
    y += LINE_HEIGHT;

    const cur_lod_text = std.fmt.bufPrint(&buf, "Current LOD: {d}", .{gs.current_lod}) catch "Current LOD: ?";
    drawTextRight(text, y, cur_lod_text, yellow);
    y += LINE_HEIGHT;

    const voxel_size: u32 = @as(u32, 1) << @intCast(gs.current_lod);
    const vs_text = std.fmt.bufPrint(&buf, "Voxel Size: {d}", .{voxel_size}) catch "Voxel Size: ?";
    drawTextRight(text, y, vs_text, yellow);
    y += LINE_HEIGHT;

    // Per-LOD chunk info
    y += LINE_HEIGHT * 0.5;
    drawTextRight(text, y, "LOD Chunks", white);
    y += LINE_HEIGHT;

    const chunks_per_lod = WorldState.TOTAL_WORLD_CHUNKS;
    for (0..GameState.MAX_LOD) |lod| {
        const lod_line = std.fmt.bufPrint(&buf, "LOD {d}: {d} chunks", .{ lod, chunks_per_lod }) catch "LOD: ?";
        drawTextRight(text, y, lod_line, yellow);
        y += LINE_HEIGHT;
    }

    const total_chunks = chunks_per_lod * GameState.MAX_LOD;
    const total_text = std.fmt.bufPrint(&buf, "Total: {d} chunks", .{total_chunks}) catch "Total: ?";
    drawTextRight(text, y, total_text, yellow);
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
