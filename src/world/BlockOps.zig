const std = @import("std");
const tracy = @import("../platform/tracy.zig");
const GameState = @import("GameState.zig");
const InventoryOps = GameState.InventoryOps;
const WorldState = @import("WorldState.zig");
const BlockState = WorldState.BlockState;
const Raycast = @import("Raycast.zig");
const Entity = @import("entity/Entity.zig");
const Physics = @import("entity/Physics.zig");
const Degrees = @import("../math/Angle.zig").Degrees;

pub fn breakBlockNoDrop(state: *GameState) void {
    breakBlockImpl(state, false);
}

pub fn breakBlock(state: *GameState) void {
    const tz = tracy.zone(@src(), "breakBlock");
    defer tz.end();
    breakBlockImpl(state, true);
}

fn breakBlockImpl(state: *GameState, allow_drop: bool) void {
    state.swing_requested = true;
    const hit = state.hit_result orelse return;
    const wx = hit.block_pos[0];
    const wy = hit.block_pos[1];
    const wz = hit.block_pos[2];
    const old_block = state.chunk_map.getBlock(wx, wy, wz);

    const air = BlockState.defaultState(.air);

    // Determine what to drop (e.g. stone → cobblestone, glass → nothing)
    const drop_block = BlockState.blockDrop(BlockState.getBlock(old_block));
    const should_drop = allow_drop and drop_block != .bedrock and drop_block != .water and drop_block != .air;

    // Door breaking: remove both halves
    if (BlockState.isDoor(old_block)) {
        state.chunk_map.setBlock(wx, wy, wz, air);
        state.markDirtyIncremental(wx, wy, wz, old_block);
        state.queueChunkSave(wx, wy, wz);

        // Find and remove the other half
        const other_y: i32 = if (BlockState.isDoorBottom(old_block)) wy + 1 else wy - 1;
        const other_block = state.chunk_map.getBlock(wx, other_y, wz);
        if (BlockState.isDoor(other_block)) {
            state.chunk_map.setBlock(wx, other_y, wz, air);
            state.markDirtyIncremental(wx, other_y, wz, other_block);
            state.queueChunkSave(wx, other_y, wz);

            const key2 = WorldState.ChunkKey.fromWorldPos(wx, other_y, wz);
            const lx2: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
            const lz2: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
            state.surface_height_map.rebuildColumnAt(key2.cx, key2.cz, lx2, lz2, &state.chunk_map);
        }

        const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
        const local_x: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
        const local_z: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
        state.surface_height_map.rebuildColumnAt(key.cx, key.cz, local_x, local_z, &state.chunk_map);
        updateFenceNeighbors(state, wx, wy, wz);
        updateStairNeighbors(state, wx, wy, wz);
        state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
        if (should_drop) {
            const drop_pos = [3]f32{
                @as(f32, @floatFromInt(wx)) + 0.5,
                @as(f32, @floatFromInt(wy)) + 0.5,
                @as(f32, @floatFromInt(wz)) + 0.5,
            };
            state.entities.spawnItemDrop(drop_pos, BlockState.getCanonicalState(BlockState.defaultState(drop_block)), 1);
        }
        return;
    }

    state.chunk_map.setBlock(wx, wy, wz, air);
    // Rebuild surface height for this column (broken block may have been the surface)
    const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const local_x: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
    const local_z: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
    state.surface_height_map.rebuildColumnAt(key.cx, key.cz, local_x, local_z, &state.chunk_map);
    state.markDirtyIncremental(wx, wy, wz, old_block);
    state.queueChunkSave(wx, wy, wz);
    updateFenceNeighbors(state, wx, wy, wz);
    updateStairNeighbors(state, wx, wy, wz);
    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
    if (should_drop) {
        const drop_pos = [3]f32{
            @as(f32, @floatFromInt(wx)) + 0.5,
            @as(f32, @floatFromInt(wy)) + 0.5,
            @as(f32, @floatFromInt(wz)) + 0.5,
        };
        state.entities.spawnItemDrop(drop_pos, BlockState.getCanonicalState(BlockState.defaultState(drop_block)), 1);
    }
}

pub fn toggleDoor(state: *GameState, wx: i32, wy: i32, wz: i32, block: BlockState.StateId) void {
    // Toggle this half
    const new_block = BlockState.toggleDoor(block);
    const old_block = state.chunk_map.getBlock(wx, wy, wz);
    state.chunk_map.setBlock(wx, wy, wz, new_block);
    state.markDirtyIncremental(wx, wy, wz, old_block);
    state.queueChunkSave(wx, wy, wz);

    // Toggle the other half
    const other_y: i32 = if (BlockState.isDoorBottom(block)) wy + 1 else wy - 1;
    const other_block = state.chunk_map.getBlock(wx, other_y, wz);
    if (BlockState.isDoor(other_block)) {
        const new_other = BlockState.toggleDoor(other_block);
        state.chunk_map.setBlock(wx, other_y, wz, new_other);
        state.markDirtyIncremental(wx, other_y, wz, other_block);
        state.queueChunkSave(wx, other_y, wz);
    }

    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
}

pub fn placeBlock(state: *GameState) void {
    const tz = tracy.zone(@src(), "placeBlock");
    defer tz.end();
    const hit = state.hit_result orelse return;
    state.swing_requested = true;

    // If clicking on a door, toggle it instead of placing
    const clicked_block = state.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (BlockState.isDoor(clicked_block)) {
        toggleDoor(state, hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], clicked_block);
        return;
    }

    // If clicking on a crafting table, open workbench crafting
    if (BlockState.getBlock(clicked_block) == .crafting_table) {
        state.inv.open_workbench_requested = true;
        return;
    }

    const stack = &state.playerInv().hotbar[state.inv.selected_slot];
    if (stack.isEmpty()) return;
    if (stack.isTool()) return; // tools can't be placed as blocks
    if (BlockState.getBlock(stack.block).isNonPlaceable()) return; // non-placeable items
    var block_state = stack.block;

    // Double slab: placing a slab on a compatible existing slab merges into a full block
    if (BlockState.getBlock(block_state) == .oak_slab) {
        if (slabCanBeReplaced(clicked_block, hit)) {
            const bx = hit.block_pos[0];
            const by = hit.block_pos[1];
            const bz = hit.block_pos[2];
            const double_slab = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.double));
            state.chunk_map.setBlock(bx, by, bz, double_slab);
            if (BlockState.isOpaque(double_slab)) {
                const skey = WorldState.ChunkKey.fromWorldPos(bx, by, bz);
                const slx: usize = @intCast(@mod(bx, @as(i32, WorldState.CHUNK_SIZE)));
                const slz: usize = @intCast(@mod(bz, @as(i32, WorldState.CHUNK_SIZE)));
                state.surface_height_map.updateBlockPlaced(skey.cx, skey.cz, slx, slz, by);
            }
            state.markDirtyIncremental(bx, by, bz, clicked_block);
            state.queueChunkSave(bx, by, bz);
            updateFenceNeighbors(state, bx, by, bz);
            state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
            InventoryOps.decrementSelectedStack(state);
            return;
        }
    }

    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (BlockState.isSolid(state.chunk_map.getBlock(px, py, pz))) return;
    if (BlockState.isSolid(block_state) and blockOverlapsPlayer(px, py, pz, state.entities.pos[Entity.PLAYER])) return;

    // Orient stairs based on player yaw, and slabs based on hit face/position
    block_state = resolveOrientation(block_state, state.camera.yaw, hit);

    // Fence placement: calculate connections from neighbors
    if (BlockState.isFence(block_state)) {
        block_state = BlockState.fenceFromConnections(
            BlockState.connectsToFence(state.chunk_map.getBlock(px, py, pz - 1)),
            BlockState.connectsToFence(state.chunk_map.getBlock(px, py, pz + 1)),
            BlockState.connectsToFence(state.chunk_map.getBlock(px + 1, py, pz)),
            BlockState.connectsToFence(state.chunk_map.getBlock(px - 1, py, pz)),
        );
    }

    // Door placement: need space for both halves
    if (BlockState.isDoor(block_state)) {
        // Check that the block above is free
        const above = state.chunk_map.getBlock(px, py + 1, pz);
        if (BlockState.isSolid(above)) return;
        if (BlockState.getBlock(above) != .air and BlockState.getBlock(above) != .water) return;

        // Place bottom half
        const old_bottom = state.chunk_map.getBlock(px, py, pz);
        state.chunk_map.setBlock(px, py, pz, block_state);
        state.markDirtyIncremental(px, py, pz, old_bottom);
        state.queueChunkSave(px, py, pz);

        // Place top half
        const top_type = BlockState.doorBottomToTop(block_state);
        const old_top = state.chunk_map.getBlock(px, py + 1, pz);
        state.chunk_map.setBlock(px, py + 1, pz, top_type);
        state.markDirtyIncremental(px, py + 1, pz, old_top);
        state.queueChunkSave(px, py + 1, pz);

        state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
        InventoryOps.decrementSelectedStack(state);
        return;
    }

    const old_block = state.chunk_map.getBlock(px, py, pz);
    state.chunk_map.setBlock(px, py, pz, block_state);
    // Update surface height if placing an opaque block
    if (BlockState.isOpaque(block_state)) {
        const key = WorldState.ChunkKey.fromWorldPos(px, py, pz);
        const local_x: usize = @intCast(@mod(px, @as(i32, WorldState.CHUNK_SIZE)));
        const local_z: usize = @intCast(@mod(pz, @as(i32, WorldState.CHUNK_SIZE)));
        state.surface_height_map.updateBlockPlaced(key.cx, key.cz, local_x, local_z, py);
    }
    state.markDirtyIncremental(px, py, pz, old_block);
    state.queueChunkSave(px, py, pz);

    // Update neighboring fences and stairs when placing any block
    updateFenceNeighbors(state, px, py, pz);
    updateStairNeighbors(state, px, py, pz);

    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
    InventoryOps.decrementSelectedStack(state);
}

pub fn pickBlock(state: *GameState) void {
    const hit = state.hit_result orelse return;
    const raw_state = state.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (raw_state == BlockState.defaultState(.air)) return;

    // Normalize oriented variants to their canonical form for inventory
    const block_state = BlockState.getCanonicalState(raw_state);

    // If already in hotbar, just select that slot
    const inv = state.playerInv();
    for (inv.hotbar, 0..) |slot, i| {
        if (slot.block == block_state) {
            state.inv.selected_slot = @intCast(i);
            return;
        }
    }

    // Survival: only select, never spawn items
    if (state.game_mode == .survival) return;

    // Creative: replace the current slot with a full stack
    // If current slot holds a tool, find first non-tool slot instead
    var target_slot = state.inv.selected_slot;
    if (inv.hotbar[target_slot].isTool()) {
        for (inv.hotbar, 0..) |s, idx| {
            if (!s.isTool()) {
                target_slot = @intCast(idx);
                break;
            }
        }
    }
    inv.hotbar[target_slot] = .{ .block = block_state, .count = Entity.MAX_STACK };
    state.inv.selected_slot = target_slot;
}

// ============================================================
// Block connection helpers
// ============================================================

fn updateFenceNeighbors(state: *GameState, wx: i32, wy: i32, wz: i32) void {
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        const nx = wx + d[0];
        const nz = wz + d[1];
        const neighbor = state.chunk_map.getBlock(nx, wy, nz);
        if (!BlockState.isFence(neighbor)) continue;

        const new_variant = BlockState.fenceFromConnections(
            BlockState.connectsToFence(state.chunk_map.getBlock(nx, wy, nz - 1)),
            BlockState.connectsToFence(state.chunk_map.getBlock(nx, wy, nz + 1)),
            BlockState.connectsToFence(state.chunk_map.getBlock(nx + 1, wy, nz)),
            BlockState.connectsToFence(state.chunk_map.getBlock(nx - 1, wy, nz)),
        );
        if (new_variant != neighbor) {
            state.chunk_map.setBlock(nx, wy, nz, new_variant);
            state.markDirtyIncremental(nx, wy, nz, neighbor);
            state.queueChunkSave(nx, wy, nz);
        }
    }
}

fn updateStairNeighbors(state: *GameState, wx: i32, wy: i32, wz: i32) void {
    updateSingleStairShape(state, wx, wy, wz);
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        updateSingleStairShape(state, wx + d[0], wy, wz + d[1]);
    }
}

fn updateSingleStairShape(state: *GameState, wx: i32, wy: i32, wz: i32) void {
    const st = state.chunk_map.getBlock(wx, wy, wz);
    if (!BlockState.isStairs(st)) return;
    const facing = BlockState.getFacing(st).?;
    const half = BlockState.getHalf(st).?;
    const new_shape = computeStairShape(state, wx, wy, wz, facing, half);
    const old_shape = BlockState.getStairShape(st).?;
    if (new_shape != old_shape) {
        const new_state = BlockState.makeStairState(facing, half, new_shape);
        state.chunk_map.setBlock(wx, wy, wz, new_state);
        state.markDirtyIncremental(wx, wy, wz, st);
        state.queueChunkSave(wx, wy, wz);
    }
}

fn computeStairShape(state: *GameState, wx: i32, wy: i32, wz: i32, facing: BlockState.Facing, half: BlockState.Half) BlockState.StairShape {
    const fd = facingDelta(facing);
    const step_neighbor = state.chunk_map.getBlock(wx + fd[0], wy, wz + fd[1]);
    if (BlockState.isStairs(step_neighbor)) {
        const sf = BlockState.getFacing(step_neighbor).?;
        const sh = BlockState.getHalf(step_neighbor).?;
        if (sh == half and isPerpendicular(facing, sf)) {
            if (isLeftOf(facing, sf)) return .inner_left;
            return .inner_right;
        }
    }
    const back_neighbor = state.chunk_map.getBlock(wx - fd[0], wy, wz - fd[1]);
    if (BlockState.isStairs(back_neighbor)) {
        const bf = BlockState.getFacing(back_neighbor).?;
        const bh = BlockState.getHalf(back_neighbor).?;
        if (bh == half and isPerpendicular(facing, bf)) {
            if (isLeftOf(facing, bf)) return .outer_left;
            return .outer_right;
        }
    }
    return .straight;
}

fn facingDelta(facing: BlockState.Facing) [2]i32 {
    return switch (facing) {
        .south => .{ 0, 1 },
        .north => .{ 0, -1 },
        .east => .{ 1, 0 },
        .west => .{ -1, 0 },
    };
}

fn isPerpendicular(a: BlockState.Facing, b: BlockState.Facing) bool {
    const a_axis = @intFromEnum(a) >> 1;
    const b_axis = @intFromEnum(b) >> 1;
    return a_axis != b_axis;
}

fn isLeftOf(facing: BlockState.Facing, other: BlockState.Facing) bool {
    return switch (facing) {
        .south => other == .east,
        .north => other == .west,
        .east => other == .north,
        .west => other == .south,
    };
}

fn slabCanBeReplaced(existing: BlockState.StateId, hit: Raycast.BlockHitResult) bool {
    const slab_type = BlockState.getSlabType(existing) orelse return false;
    const above = hit.hit_pos[1] - @floor(hit.hit_pos[1]) > 0.5;
    return switch (slab_type) {
        .bottom => hit.direction == .up or (above and hit.direction != .down),
        .top => hit.direction == .down or (!above and hit.direction != .up),
        .double => false,
    };
}

fn resolveOrientation(block_state: BlockState.StateId, yaw: Degrees, hit: Raycast.BlockHitResult) BlockState.StateId {
    const block = BlockState.getBlock(block_state);
    const norm_yaw = yaw.normalize360().value;
    switch (block) {
        .oak_stairs => {
            const facing: BlockState.Facing = if (norm_yaw >= 45.0 and norm_yaw < 135.0)
                .east
            else if (norm_yaw >= 135.0 and norm_yaw < 225.0)
                .north
            else if (norm_yaw >= 225.0 and norm_yaw < 315.0)
                .west
            else
                .south;
            const half: BlockState.Half = if (hit.direction == .down)
                .top
            else if (hit.direction == .up)
                .bottom
            else blk: {
                const frac_y = hit.hit_pos[1] - @floor(hit.hit_pos[1]);
                break :blk if (frac_y >= 0.5) .top else .bottom;
            };
            return BlockState.makeStairState(facing, half, .straight);
        },
        .oak_slab => {
            if (hit.direction == .down) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
            if (hit.direction == .up) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
            const frac_y = hit.hit_pos[1] - @floor(hit.hit_pos[1]);
            if (frac_y >= 0.5) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
            return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
        },
        .torch => {
            return switch (hit.direction) {
                .up => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.standing)),
                .south => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_north)),
                .north => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_south)),
                .east => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_west)),
                .west => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_east)),
                .down => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.standing)),
            };
        },
        .ladder => {
            return switch (hit.direction) {
                .south => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.south)),
                .north => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.north)),
                .east => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.east)),
                .west => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.west)),
                else => block_state,
            };
        },
        .oak_door => {
            const facing: BlockState.Facing = if (norm_yaw >= 45.0 and norm_yaw < 135.0)
                .east
            else if (norm_yaw >= 135.0 and norm_yaw < 225.0)
                .north
            else if (norm_yaw >= 225.0 and norm_yaw < 315.0)
                .west
            else
                .south;
            return BlockState.makeDoorState(facing, .bottom, false);
        },
        .oak_fence => return BlockState.defaultState(.oak_fence),
        else => return block_state,
    }
}

pub fn blockOverlapsPlayer(bx: i32, by: i32, bz: i32, pos: [3]f32) bool {
    const fbx: f32 = @floatFromInt(bx);
    const fby: f32 = @floatFromInt(by);
    const fbz: f32 = @floatFromInt(bz);
    return fbx + 1.0 > pos[0] - Physics.PLAYER_HALF_W and fbx < pos[0] + Physics.PLAYER_HALF_W and
        fby + 1.0 > pos[1] and fby < pos[1] + Physics.PLAYER_HEIGHT and
        fbz + 1.0 > pos[2] - Physics.PLAYER_HALF_W and fbz < pos[2] + Physics.PLAYER_HALF_W;
}
