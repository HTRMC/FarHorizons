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
    const pos = hit.block_pos;
    const old_block = state.chunk_map.getBlock(pos);
    if (!state.multiplayer_client and BlockState.getBlock(old_block) != .air) state.stats.blocks_mined +%= 1;

    const air = BlockState.defaultState(.air);

    // Determine what to drop (e.g. stone → cobblestone, glass → nothing)
    const drop_block = BlockState.blockDrop(BlockState.getBlock(old_block));
    const should_drop = allow_drop and drop_block != .bedrock and drop_block != .water and drop_block != .air;

    // Door breaking: remove both halves
    if (BlockState.isDoor(old_block)) {
        state.chunk_map.setBlock(pos, air);
        state.markDirtyIncremental(pos, old_block);
        state.queueChunkSave(pos);

        // Find and remove the other half
        const other_pos = pos.offset(0, if (BlockState.isDoorBottom(old_block)) 1 else -1, 0);
        const other_block = state.chunk_map.getBlock(other_pos);
        if (BlockState.isDoor(other_block)) {
            state.chunk_map.setBlock(other_pos, air);
            state.markDirtyIncremental(other_pos, other_block);
            state.queueChunkSave(other_pos);
            rebuildSurfaceColumn(state, other_pos);
        }

        rebuildSurfaceColumn(state, pos);
        updateFenceNeighbors(state, pos);
        updateStairNeighbors(state, pos);
        state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
        if (should_drop) dropItem(state, pos, drop_block);
        return;
    }

    state.chunk_map.setBlock(pos, air);
    rebuildSurfaceColumn(state, pos);
    state.markDirtyIncremental(pos, old_block);
    state.queueChunkSave(pos);
    updateFenceNeighbors(state, pos);
    updateStairNeighbors(state, pos);
    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
    if (should_drop) dropItem(state, pos, drop_block);
}

fn rebuildSurfaceColumn(state: *GameState, pos: WorldState.WorldBlockPos) void {
    const key = pos.toChunkKey();
    const local = pos.toLocal();
    state.surface_height_map.rebuildColumnAt(key.cx, key.cz, local.x, local.z, &state.chunk_map);
}

fn dropItem(state: *GameState, pos: WorldState.WorldBlockPos, drop_block: BlockState.Block) void {
    const drop_pos = [3]f32{
        @as(f32, @floatFromInt(pos.x)) + 0.5,
        @as(f32, @floatFromInt(pos.y)) + 0.5,
        @as(f32, @floatFromInt(pos.z)) + 0.5,
    };
    state.entities.spawnItemDrop(drop_pos, BlockState.getCanonicalState(BlockState.defaultState(drop_block)), 1);
}

pub fn toggleDoor(state: *GameState, pos: WorldState.WorldBlockPos, block: BlockState.StateId) void {
    // Toggle this half
    const new_block = BlockState.toggleDoor(block);
    const old_block = state.chunk_map.getBlock(pos);
    state.chunk_map.setBlock(pos, new_block);
    state.markDirtyIncremental(pos, old_block);
    state.queueChunkSave(pos);

    // Toggle the other half
    const other_pos = pos.offset(0, if (BlockState.isDoorBottom(block)) 1 else -1, 0);
    const other_block = state.chunk_map.getBlock(other_pos);
    if (BlockState.isDoor(other_block)) {
        const new_other = BlockState.toggleDoor(other_block);
        state.chunk_map.setBlock(other_pos, new_other);
        state.markDirtyIncremental(other_pos, other_block);
        state.queueChunkSave(other_pos);
    }

    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
}

pub fn placeBlock(state: *GameState) void {
    const tz = tracy.zone(@src(), "placeBlock");
    defer tz.end();
    const hit = state.hit_result orelse return;
    state.swing_requested = true;

    // If clicking on a door, toggle it instead of placing
    const clicked_block = state.chunk_map.getBlock(hit.block_pos);
    if (BlockState.isDoor(clicked_block)) {
        toggleDoor(state, hit.block_pos, clicked_block);
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
            const double_slab = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.double));
            state.chunk_map.setBlock(hit.block_pos, double_slab);
            if (BlockState.isOpaque(double_slab)) {
                updateSurfaceHeight(state, hit.block_pos);
            }
            state.markDirtyIncremental(hit.block_pos, clicked_block);
            state.queueChunkSave(hit.block_pos);
            updateFenceNeighbors(state, hit.block_pos);
            state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
            if (!state.multiplayer_client) state.stats.blocks_placed +%= 1;
            InventoryOps.decrementSelectedStack(state);
            return;
        }
    }

    const n = hit.direction.normal();
    const place_pos = hit.block_pos.offset(n[0], n[1], n[2]);
    if (BlockState.isSolid(state.chunk_map.getBlock(place_pos))) return;
    if (BlockState.isSolid(block_state) and blockOverlapsPlayer(place_pos, state.entities.pos[Entity.PLAYER])) return;

    // Orient stairs based on player yaw, and slabs based on hit face/position
    block_state = resolveOrientation(block_state, state.camera.yaw, hit);

    // Fence placement: calculate connections from neighbors
    if (BlockState.isFence(block_state)) {
        block_state = BlockState.fenceFromConnections(
            BlockState.connectsToFence(state.chunk_map.getBlock(place_pos.offset(0, 0, -1))),
            BlockState.connectsToFence(state.chunk_map.getBlock(place_pos.offset(0, 0, 1))),
            BlockState.connectsToFence(state.chunk_map.getBlock(place_pos.offset(1, 0, 0))),
            BlockState.connectsToFence(state.chunk_map.getBlock(place_pos.offset(-1, 0, 0))),
        );
    }

    // Door placement: need space for both halves
    if (BlockState.isDoor(block_state)) {
        // Check that the block above is free
        const above_pos = place_pos.offset(0, 1, 0);
        const above = state.chunk_map.getBlock(above_pos);
        if (BlockState.isSolid(above)) return;
        if (BlockState.getBlock(above) != .air and BlockState.getBlock(above) != .water) return;

        // Place bottom half
        const old_bottom = state.chunk_map.getBlock(place_pos);
        state.chunk_map.setBlock(place_pos, block_state);
        state.markDirtyIncremental(place_pos, old_bottom);
        state.queueChunkSave(place_pos);

        // Place top half
        const top_type = BlockState.doorBottomToTop(block_state);
        const old_top = state.chunk_map.getBlock(above_pos);
        state.chunk_map.setBlock(above_pos, top_type);
        state.markDirtyIncremental(above_pos, old_top);
        state.queueChunkSave(above_pos);

        state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
        if (!state.multiplayer_client) state.stats.blocks_placed +%= 1;
        InventoryOps.decrementSelectedStack(state);
        return;
    }

    const old_block = state.chunk_map.getBlock(place_pos);
    state.chunk_map.setBlock(place_pos, block_state);
    // Update surface height if placing an opaque block
    if (BlockState.isOpaque(block_state)) {
        updateSurfaceHeight(state, place_pos);
    }
    state.markDirtyIncremental(place_pos, old_block);
    state.queueChunkSave(place_pos);

    // Update neighboring fences and stairs when placing any block
    updateFenceNeighbors(state, place_pos);
    updateStairNeighbors(state, place_pos);

    state.hit_result = Raycast.raycast(&state.chunk_map, state.camera.position, state.camera.getForward());
    if (!state.multiplayer_client) state.stats.blocks_placed +%= 1;
    InventoryOps.decrementSelectedStack(state);
}

fn updateSurfaceHeight(state: *GameState, pos: WorldState.WorldBlockPos) void {
    const key = pos.toChunkKey();
    const local = pos.toLocal();
    state.surface_height_map.updateBlockPlaced(key.cx, key.cz, local.x, local.z, pos.y);
}

pub fn pickBlock(state: *GameState) void {
    const hit = state.hit_result orelse return;
    const raw_state = state.chunk_map.getBlock(hit.block_pos);
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

fn updateFenceNeighbors(state: *GameState, pos: WorldState.WorldBlockPos) void {
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        const neighbor_pos = pos.offset(d[0], 0, d[1]);
        const neighbor = state.chunk_map.getBlock(neighbor_pos);
        if (!BlockState.isFence(neighbor)) continue;

        const new_variant = BlockState.fenceFromConnections(
            BlockState.connectsToFence(state.chunk_map.getBlock(neighbor_pos.offset(0, 0, -1))),
            BlockState.connectsToFence(state.chunk_map.getBlock(neighbor_pos.offset(0, 0, 1))),
            BlockState.connectsToFence(state.chunk_map.getBlock(neighbor_pos.offset(1, 0, 0))),
            BlockState.connectsToFence(state.chunk_map.getBlock(neighbor_pos.offset(-1, 0, 0))),
        );
        if (new_variant != neighbor) {
            state.chunk_map.setBlock(neighbor_pos, new_variant);
            state.markDirtyIncremental(neighbor_pos, neighbor);
            state.queueChunkSave(neighbor_pos);
        }
    }
}

fn updateStairNeighbors(state: *GameState, pos: WorldState.WorldBlockPos) void {
    updateSingleStairShape(state, pos);
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        updateSingleStairShape(state, pos.offset(d[0], 0, d[1]));
    }
}

fn updateSingleStairShape(state: *GameState, pos: WorldState.WorldBlockPos) void {
    const st = state.chunk_map.getBlock(pos);
    if (!BlockState.isStairs(st)) return;
    const facing = BlockState.getFacing(st).?;
    const half = BlockState.getHalf(st).?;
    const new_shape = computeStairShape(state, pos, facing, half);
    const old_shape = BlockState.getStairShape(st).?;
    if (new_shape != old_shape) {
        const new_state = BlockState.makeStairState(facing, half, new_shape);
        state.chunk_map.setBlock(pos, new_state);
        state.markDirtyIncremental(pos, st);
        state.queueChunkSave(pos);
    }
}

fn computeStairShape(state: *GameState, pos: WorldState.WorldBlockPos, facing: BlockState.Facing, half: BlockState.Half) BlockState.StairShape {
    const fd = facingDelta(facing);
    const step_neighbor = state.chunk_map.getBlock(pos.offset(fd[0], 0, fd[1]));
    if (BlockState.isStairs(step_neighbor)) {
        const sf = BlockState.getFacing(step_neighbor).?;
        const sh = BlockState.getHalf(step_neighbor).?;
        if (sh == half and isPerpendicular(facing, sf)) {
            if (isLeftOf(facing, sf)) return .inner_left;
            return .inner_right;
        }
    }
    const back_neighbor = state.chunk_map.getBlock(pos.offset(-fd[0], 0, -fd[1]));
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

pub fn blockOverlapsPlayer(block_pos: WorldState.WorldBlockPos, player_pos: [3]f32) bool {
    const fbx: f32 = @floatFromInt(block_pos.x);
    const fby: f32 = @floatFromInt(block_pos.y);
    const fbz: f32 = @floatFromInt(block_pos.z);
    return fbx + 1.0 > player_pos[0] - Physics.PLAYER_HALF_W and fbx < player_pos[0] + Physics.PLAYER_HALF_W and
        fby + 1.0 > player_pos[1] and fby < player_pos[1] + Physics.PLAYER_HEIGHT and
        fbz + 1.0 > player_pos[2] - Physics.PLAYER_HALF_W and fbz < player_pos[2] + Physics.PLAYER_HALF_W;
}
