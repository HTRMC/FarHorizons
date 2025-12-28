/// BlockInteraction - Handles block breaking and placing
/// Port of Minecraft's MultiPlayerGameMode block interaction logic
const std = @import("std");
const shared = @import("Shared");
const world = @import("World");

const Logger = shared.Logger;
const Vec3 = shared.Vec3;
const BlockEntry = shared.BlockEntry;
const Direction = shared.Direction;
const Camera = shared.Camera;
const raycast = shared.Raycast;
const BlockHitResult = raycast.BlockHitResult;
const AABB = raycast.AABB;
const ChunkManager = world.ChunkManager;

pub const BlockInteraction = struct {
    const Self = @This();
    const logger = Logger.init("BlockInteraction");

    /// Maximum reach distance for block interaction (in blocks)
    pub const BLOCK_REACH: f32 = 5.0;

    /// Current hit result from raycasting
    hit_result: ?BlockHitResult = null,

    /// Cooldown counter
    cooldown: u32 = 0,

    /// Currently selected block for placing
    selected_block: BlockEntry = BlockEntry.simple(1), // Default to stone

    /// Reference to chunk manager
    chunk_manager: *ChunkManager,

    pub fn init(chunk_manager: *ChunkManager) Self {
        return .{
            .chunk_manager = chunk_manager,
        };
    }

    /// Update the raycast hit result based on camera position and direction
    /// Call this every frame
    pub fn updateHitResult(self: *Self, camera: *const Camera) void {
        const eye_pos = camera.position;
        const forward = camera.forward;

        // Calculate ray end point
        const to = Vec3{
            .x = eye_pos.x + forward.x * BLOCK_REACH,
            .y = eye_pos.y + forward.y * BLOCK_REACH,
            .z = eye_pos.z + forward.z * BLOCK_REACH,
        };

        // Perform raycast
        self.hit_result = self.performRaycast(eye_pos, to);
    }

    /// Perform raycast against loaded chunks
    fn performRaycast(self: *Self, from: Vec3, to: Vec3) ?BlockHitResult {
        const Context = struct {
            cm: *ChunkManager,
        };

        const ctx = Context{ .cm = self.chunk_manager };

        const result = raycast.traverseBlocks(
            from,
            to,
            Context,
            ctx,
            struct {
                fn getShape(c: Context, pos: BlockHitResult.BlockPos) ?[]const AABB {
                    // Get block at position
                    const entry = c.cm.getBlockAt(pos.x, pos.y, pos.z) orelse return null;

                    // Skip air blocks
                    if (entry.isAir()) return null;

                    // For now, use unit cube for all solid blocks
                    // TODO: Use actual VoxelShape from block
                    const S = struct {
                        const unit_cube = [_]AABB{AABB.init(0, 0, 0, 1, 1, 1)};
                    };
                    return &S.unit_cube;
                }
            }.getShape,
        );

        // Return null if miss
        if (result.miss) return null;
        return result;
    }

    /// Tick - update cooldown
    pub fn tick(self: *Self) void {
        if (self.cooldown > 0) {
            self.cooldown -= 1;
        }
    }

    /// Handle left click (break block)
    /// Returns true if a block was broken
    pub fn handleLeftClick(self: *Self) bool {
        if (self.cooldown > 0) return false;

        const hit = self.hit_result orelse return false;

        // Break the block at hit position
        const pos = hit.block_pos;

        // Set to air
        if (self.chunk_manager.setBlockAt(pos.x, pos.y, pos.z, BlockEntry.AIR)) {
            logger.info("Broke block at ({}, {}, {})", .{ pos.x, pos.y, pos.z });
            return true;
        }

        return false;
    }

    /// Handle right click (place block)
    /// Returns true if a block was placed
    pub fn handleRightClick(self: *Self) bool {
        if (self.cooldown > 0) return false;

        const hit = self.hit_result orelse return false;

        // Get placement position (adjacent to hit face)
        const place_pos = getPlacementPosition(hit.block_pos, hit.direction);

        // Check if we can place here (must be air)
        const existing = self.chunk_manager.getBlockAt(place_pos.x, place_pos.y, place_pos.z);
        if (existing) |entry| {
            if (!entry.isAir()) {
                return false; // Can't place in non-air block
            }
        }

        // Place the selected block
        if (self.chunk_manager.setBlockAt(place_pos.x, place_pos.y, place_pos.z, self.selected_block)) {
            logger.info("Placed block at ({}, {}, {})", .{ place_pos.x, place_pos.y, place_pos.z });
            return true;
        }

        return false;
    }

    /// Handle middle click (pick block)
    pub fn handleMiddleClick(self: *Self) void {
        const hit = self.hit_result orelse return;

        // Get the block at hit position
        const pos = hit.block_pos;
        if (self.chunk_manager.getBlockAt(pos.x, pos.y, pos.z)) |entry| {
            if (!entry.isAir()) {
                self.selected_block = entry;
                logger.info("Picked block {} at ({}, {}, {})", .{ entry.id, pos.x, pos.y, pos.z });
            }
        }
    }

    /// Set the selected block for placing
    pub fn setSelectedBlock(self: *Self, entry: BlockEntry) void {
        self.selected_block = entry;
    }

    /// Cycle to next block type
    pub fn cycleSelectedBlock(self: *Self, forward: bool) void {
        const max_id: u8 = 16; // Maximum block ID
        if (forward) {
            self.selected_block.id = if (self.selected_block.id >= max_id) 1 else self.selected_block.id + 1;
        } else {
            self.selected_block.id = if (self.selected_block.id <= 1) max_id else self.selected_block.id - 1;
        }
        // Skip air (id=0)
        if (self.selected_block.id == 0) {
            self.selected_block.id = if (forward) 1 else max_id;
        }
        logger.info("Selected block: {}", .{self.selected_block.id});
    }

    /// Get the current hit result (for rendering crosshair/outline)
    pub fn getHitResult(self: *const Self) ?BlockHitResult {
        return self.hit_result;
    }

    /// Check if currently looking at a block
    pub fn isLookingAtBlock(self: *const Self) bool {
        return self.hit_result != null;
    }
};

/// Calculate block position adjacent to a face
/// Equivalent to Minecraft's BlockPos.relative(Direction)
fn getPlacementPosition(pos: BlockHitResult.BlockPos, direction: Direction) BlockHitResult.BlockPos {
    const offset = direction.offset();
    return .{
        .x = pos.x + offset[0],
        .y = pos.y + offset[1],
        .z = pos.z + offset[2],
    };
}
