/// Chunk data structure - 16x16x16 blocks
/// Matches Minecraft's chunk section concept

pub const CHUNK_SIZE = 16;
pub const CHUNK_VOLUME = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

/// Block types
pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    oak_slab = 2,

    pub fn isOpaque(self: BlockType) bool {
        return switch (self) {
            .air => false,
            .stone => true,
            .oak_slab => false, // Slab is not full block
        };
    }

    pub fn isSolid(self: BlockType) bool {
        return self != .air;
    }
};

/// A 16x16x16 chunk section
pub const Chunk = struct {
    blocks: [CHUNK_VOLUME]BlockType,

    pub fn init() Chunk {
        return .{
            .blocks = .{.air} ** CHUNK_VOLUME,
        };
    }

    /// Get block at local coordinates (0-15)
    pub fn getBlock(self: *const Chunk, x: u32, y: u32, z: u32) BlockType {
        if (x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return .air;
        }
        return self.blocks[getIndex(x, y, z)];
    }

    /// Set block at local coordinates (0-15)
    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
        if (x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return;
        }
        self.blocks[getIndex(x, y, z)] = block;
    }

    /// Check if face should be rendered (neighbor is air or transparent)
    pub fn shouldRenderFace(self: *const Chunk, x: i32, y: i32, z: i32) bool {
        // Out of bounds = air = render face
        if (x < 0 or y < 0 or z < 0 or x >= CHUNK_SIZE or y >= CHUNK_SIZE or z >= CHUNK_SIZE) {
            return true;
        }
        const neighbor = self.getBlock(@intCast(x), @intCast(y), @intCast(z));
        // Render if neighbor is not opaque
        return !neighbor.isOpaque();
    }

    /// Generate a test chunk with some blocks
    pub fn generateTestChunk() Chunk {
        var chunk = Chunk.init();

        // Create a simple terrain: stone base with some slabs on top
        for (0..CHUNK_SIZE) |x| {
            for (0..CHUNK_SIZE) |z| {
                // Stone layer at y=0
                chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);

                // Random-ish pattern for second layer
                const hash = (x * 7 + z * 13) % 5;
                if (hash < 2) {
                    chunk.setBlock(@intCast(x), 1, @intCast(z), .stone);
                } else if (hash == 2) {
                    chunk.setBlock(@intCast(x), 1, @intCast(z), .oak_slab);
                }
                // else air

                // Some scattered blocks at y=2
                if ((x + z) % 7 == 0) {
                    chunk.setBlock(@intCast(x), 2, @intCast(z), .stone);
                }
            }
        }

        return chunk;
    }

    fn getIndex(x: u32, y: u32, z: u32) usize {
        return @as(usize, y) * CHUNK_SIZE * CHUNK_SIZE + @as(usize, z) * CHUNK_SIZE + @as(usize, x);
    }
};
