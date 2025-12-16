/// Chunk data structure - 16x16x16 blocks
/// Matches Minecraft's chunk section concept
const voxel_shape = @import("VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const Direction = voxel_shape.Direction;
const shapes_mod = @import("Shapes.zig");
const Shapes = shapes_mod.Shapes;
const ChunkAccess = @import("ChunkAccess.zig").ChunkAccess;
const occlusion = @import("OcclusionCache.zig");
const blocks = @import("block/Blocks.zig");
const block_mod = @import("block/Block.zig");
const BlockState = block_mod.BlockState;

pub const CHUNK_SIZE = 16;
pub const CHUNK_VOLUME = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

/// Block entry storing both ID and state
/// Packed into 16 bits for efficient storage
pub const BlockEntry = packed struct {
    /// Block ID (0-255)
    id: u8,
    /// Block state (packed properties)
    state: BlockState,

    pub const AIR = BlockEntry{ .id = 0, .state = .{} };

    /// Create a simple block entry with default state
    pub fn simple(id: u8) BlockEntry {
        return .{ .id = id, .state = .{} };
    }

    /// Create a slab block entry
    pub fn slab(id: u8, slab_type: BlockState.SlabType) BlockEntry {
        return .{ .id = id, .state = BlockState.slab(slab_type) };
    }

    /// Create a stair block entry
    pub fn stair(
        id: u8,
        facing: BlockState.StairFacing,
        half: BlockState.StairHalf,
        shape: BlockState.StairShape,
    ) BlockEntry {
        return .{ .id = id, .state = BlockState.stair(facing, half, shape) };
    }

    /// Get the block definition
    pub fn getBlock(self: BlockEntry) *const blocks.block_mod.Block {
        return blocks.getBlock(self.id);
    }

    /// Get the VoxelShape for this block entry
    pub fn getShape(self: BlockEntry) *const VoxelShape {
        return blocks.getShape(self.id, self.state);
    }

    /// Check if block is opaque
    pub fn isOpaque(self: BlockEntry) bool {
        return blocks.isOpaque(self.id, self.state);
    }

    /// Check if block is solid
    pub fn isSolid(self: BlockEntry) bool {
        return blocks.isSolid(self.id, self.state);
    }

    /// Check if this is air
    pub fn isAir(self: BlockEntry) bool {
        return self.id == 0;
    }
};

/// Legacy BlockType enum for backwards compatibility
/// Maps to BlockEntry internally
pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    oak_slab = 2,

    pub fn isOpaque(self: BlockType) bool {
        return self.toEntry().isOpaque();
    }

    pub fn isSolid(self: BlockType) bool {
        return self.toEntry().isSolid();
    }

    pub fn getShape(self: BlockType) *const VoxelShape {
        return self.toEntry().getShape();
    }

    /// Convert to BlockEntry with default state
    pub fn toEntry(self: BlockType) BlockEntry {
        return BlockEntry.simple(@intFromEnum(self));
    }
};

/// A 16x16x16 chunk section
pub const Chunk = struct {
    /// Block storage - stores BlockEntry (id + state)
    block_entries: [CHUNK_VOLUME]BlockEntry,

    pub fn init() Chunk {
        return .{
            .block_entries = .{BlockEntry.AIR} ** CHUNK_VOLUME,
        };
    }

    /// Get block entry at local coordinates (0-15)
    pub fn getBlockEntry(self: *const Chunk, x: u32, y: u32, z: u32) BlockEntry {
        if (x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return BlockEntry.AIR;
        }
        return self.block_entries[getIndex(x, y, z)];
    }

    /// Set block entry at local coordinates (0-15)
    pub fn setBlockEntry(self: *Chunk, x: u32, y: u32, z: u32, entry: BlockEntry) void {
        if (x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return;
        }
        self.block_entries[getIndex(x, y, z)] = entry;
    }

    /// Legacy: Get block type at local coordinates (ignores state)
    pub fn getBlock(self: *const Chunk, x: u32, y: u32, z: u32) BlockType {
        const entry = self.getBlockEntry(x, y, z);
        return @enumFromInt(entry.id);
    }

    /// Legacy: Set block at local coordinates (default state)
    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
        self.setBlockEntry(x, y, z, block.toEntry());
    }

    /// Check if face should be rendered (neighbor is air or transparent)
    /// DEPRECATED: Use shouldRenderFaceVoxel for shape-aware culling
    pub fn shouldRenderFace(self: *const Chunk, x: i32, y: i32, z: i32) bool {
        // Out of bounds = air = render face
        if (x < 0 or y < 0 or z < 0 or x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return true;
        }
        const neighbor = self.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
        // Render if neighbor is not opaque
        return !neighbor.isOpaque();
    }

    /// Shape-aware face culling using VoxelShapes
    /// Returns true if face SHOULD be rendered, false if it should be culled
    ///
    /// Parameters:
    /// - x, y, z: Block position within chunk
    /// - direction: Which face we're checking
    /// - block: The block entry at this position
    /// - chunk_access: Optional cross-chunk access for boundary lookups
    pub fn shouldRenderFaceVoxelEntry(
        self: *const Chunk,
        x: i32,
        y: i32,
        z: i32,
        direction: Direction,
        block: BlockEntry,
        chunk_access: ?*const ChunkAccess,
    ) bool {
        // Get neighbor position
        const off = direction.offset();
        const nx = x + off[0];
        const ny = y + off[1];
        const nz = z + off[2];

        // Get neighbor block entry
        const neighbor: BlockEntry = blk: {
            if (chunk_access) |access| {
                break :blk access.getBlockEntry(nx, ny, nz);
            }
            // No cross-chunk access - check bounds
            if (nx < 0 or ny < 0 or nz < 0 or
                nx >= CHUNK_SIZE or ny >= CHUNK_SIZE or nz >= CHUNK_SIZE)
            {
                break :blk BlockEntry.AIR;
            }
            break :blk self.getBlockEntry(@intCast(nx), @intCast(ny), @intCast(nz));
        };

        // Get shapes and check occlusion
        const block_shape = block.getShape();
        const neighbor_shape = neighbor.getShape();

        return occlusion.shouldRenderFace(block_shape, neighbor_shape, direction);
    }

    /// Per-element face culling for precise model face handling
    /// Takes the element's bounding box in block coordinates (0-16) and checks
    /// if that specific region of the face is occluded by the neighbor
    ///
    /// Parameters:
    /// - x, y, z: Block position within chunk
    /// - direction: Which face direction we're checking (after model rotation)
    /// - element_from, element_to: Element bounds in block coords (0-16)
    /// - chunk_access: Optional cross-chunk access for boundary lookups
    pub fn shouldRenderElementFace(
        self: *const Chunk,
        x: i32,
        y: i32,
        z: i32,
        direction: Direction,
        element_from: [3]f32,
        element_to: [3]f32,
        chunk_access: ?*const ChunkAccess,
    ) bool {
        // Get neighbor position
        const off = direction.offset();
        const nx = x + off[0];
        const ny = y + off[1];
        const nz = z + off[2];

        // Get neighbor block entry
        const neighbor: BlockEntry = blk: {
            if (chunk_access) |access| {
                break :blk access.getBlockEntry(nx, ny, nz);
            }
            // No cross-chunk access - check bounds
            if (nx < 0 or ny < 0 or nz < 0 or
                nx >= CHUNK_SIZE or ny >= CHUNK_SIZE or nz >= CHUNK_SIZE)
            {
                break :blk BlockEntry.AIR;
            }
            break :blk self.getBlockEntry(@intCast(nx), @intCast(ny), @intCast(nz));
        };

        // Get neighbor shape
        const neighbor_shape = neighbor.getShape();

        // Fast path: neighbor is empty (air) - always render
        if (neighbor_shape.isEmpty()) return true;

        // Fast path: neighbor is full block - never render (occluded)
        if (neighbor_shape.isFullBlock()) return false;

        // Compute face bounds from element bounds
        // The UV coordinates depend on the face direction
        const face_bounds = computeFaceBounds(direction, element_from, element_to);

        // Check if the neighbor's opposite face covers this specific region
        // If covered, the face is occluded and should NOT render
        return !neighbor_shape.faceCoversRegion(direction.opposite(), face_bounds);
    }

    /// Compute 2D face bounds [u_min, v_min, u_max, v_max] from 3D element bounds
    /// The mapping depends on which face direction we're looking at:
    /// - DOWN/UP: u=x, v=z
    /// - NORTH/SOUTH: u=x, v=y
    /// - WEST/EAST: u=y, v=z (note: getSlice uses this order)
    fn computeFaceBounds(direction: Direction, from: [3]f32, to: [3]f32) [4]f32 {
        return switch (direction) {
            // Y-axis faces: u=x, v=z
            .down, .up => .{ from[0], from[2], to[0], to[2] },
            // Z-axis faces: u=x, v=y
            .north, .south => .{ from[0], from[1], to[0], to[1] },
            // X-axis faces: u=y, v=z (matches getSlice y×z)
            .west, .east => .{ from[1], from[2], to[1], to[2] },
        };
    }

    /// Legacy: Shape-aware face culling (ignores state)
    pub fn shouldRenderFaceVoxel(
        self: *const Chunk,
        x: i32,
        y: i32,
        z: i32,
        direction: Direction,
        block: BlockType,
        chunk_access: ?*const ChunkAccess,
    ) bool {
        return self.shouldRenderFaceVoxelEntry(x, y, z, direction, block.toEntry(), chunk_access);
    }

    /// Generate a test chunk with blocks including slabs of different types
    pub fn generateTestChunk() Chunk {
        var chunk = Chunk.init();

        // Create a terrain with stone base
        for (0..CHUNK_SIZE) |x| {
            for (0..CHUNK_SIZE) |z| {
                // Stone layer at y=0
                chunk.setBlockEntry(@intCast(x), 0, @intCast(z), BlockEntry.simple(1)); // stone
            }
        }

        // Create a row of adjacent bottom slabs at y=1 (for testing side face culling)
        // These should have their shared side faces culled
        for (0..8) |x| {
            chunk.setBlockEntry(@intCast(x), 1, 4, BlockEntry.slab(2, .bottom));
        }

        // Create a 2x2 grid of adjacent bottom slabs
        for (0..4) |x| {
            for (0..4) |z| {
                chunk.setBlockEntry(@intCast(x + 10), 1, @intCast(z + 10), BlockEntry.slab(2, .bottom));
            }
        }

        // Place stone blocks above some bottom slabs (to test UP face rendering)
        chunk.setBlockEntry(0, 2, 4, BlockEntry.simple(1)); // stone above first slab
        chunk.setBlockEntry(2, 2, 4, BlockEntry.simple(1)); // stone above third slab

        // Create top slabs at y=1
        for (0..4) |x| {
            chunk.setBlockEntry(@intCast(x), 1, 8, BlockEntry.slab(2, .top));
        }

        // Place stone blocks below top slabs (to test DOWN face rendering)
        chunk.setBlockEntry(0, 0, 8, BlockEntry.simple(1)); // already stone from layer 0

        // Mixed pattern for variety
        for (0..CHUNK_SIZE) |x| {
            for (0..CHUNK_SIZE) |z| {
                const hash = (x * 7 + z * 13) % 11;
                if (hash == 0 and x >= 4 and z >= 0 and z < 4) {
                    chunk.setBlockEntry(@intCast(x), 1, @intCast(z), BlockEntry.simple(1)); // stone
                }
            }
        }

        // Row of stairs facing different directions
        chunk.setBlockEntry(0, 1, 12, BlockEntry.stair(9, .north, .bottom, .straight));
        chunk.setBlockEntry(1, 1, 12, BlockEntry.stair(9, .east, .bottom, .straight));
        chunk.setBlockEntry(2, 1, 12, BlockEntry.stair(9, .south, .bottom, .straight));
        chunk.setBlockEntry(3, 1, 12, BlockEntry.stair(9, .west, .bottom, .straight));

        // Corner stairs (inner and outer)
        chunk.setBlockEntry(5, 1, 12, BlockEntry.stair(9, .north, .bottom, .inner_left));
        chunk.setBlockEntry(6, 1, 12, BlockEntry.stair(9, .north, .bottom, .inner_right));
        chunk.setBlockEntry(7, 1, 12, BlockEntry.stair(9, .north, .bottom, .outer_left));
        chunk.setBlockEntry(8, 1, 12, BlockEntry.stair(9, .north, .bottom, .outer_right));

        // Top half stairs
        chunk.setBlockEntry(10, 1, 12, BlockEntry.stair(9, .east, .top, .straight));
        chunk.setBlockEntry(11, 1, 12, BlockEntry.stair(9, .west, .top, .straight));

        // Crafting table
        chunk.setBlockEntry(13, 1, 12, BlockEntry.simple(10)); // crafting_table

        return chunk;
    }

    fn getIndex(x: u32, y: u32, z: u32) usize {
        return @as(usize, y) * CHUNK_SIZE * CHUNK_SIZE + @as(usize, z) * CHUNK_SIZE + @as(usize, x);
    }
};
