/// AmbientOcclusion - Calculates per-vertex ambient occlusion for block faces
/// Based on Minecraft's smooth lighting algorithm
const std = @import("std");
const shared = @import("Shared");
const ChunkAccess = shared.ChunkAccess;
const BlockEntry = shared.BlockEntry;
const Direction = shared.Direction;

/// AO brightness values (Minecraft uses these specific values)
/// Index 0 = fully occluded (darkest), Index 3 = no occlusion (brightest)
pub const AO_BRIGHTNESS: [4]f32 = .{ 0.2, 0.5, 0.8, 1.0 };

/// Neighbor offsets for AO calculation
/// For each face direction and each vertex, we need 3 neighbor positions:
/// [side1_offset, side2_offset, corner_offset]
/// All offsets are relative to block position
const AoNeighborOffsets = struct {
    /// For each of 4 vertices: [side1, side2, corner] as [3]i32 offsets
    offsets: [4][3][3]i32,
};

/// Pre-computed neighbor offsets for each face direction
/// The offsets define which blocks to sample for AO at each vertex corner
const AO_NEIGHBOR_TABLE: [6]AoNeighborOffsets = computeAoNeighborTable();

fn computeAoNeighborTable() [6]AoNeighborOffsets {
    var table: [6]AoNeighborOffsets = undefined;

    // DOWN face (Y-) - vertices order from FaceInfo:
    // v0: (minX, minY, maxZ), v1: (minX, minY, minZ), v2: (maxX, minY, minZ), v3: (maxX, minY, maxZ)
    // Face normal: (0, -1, 0)
    table[@intFromEnum(Direction.down)] = .{ .offsets = .{
        // v0 (minX, minY, maxZ): corner at -X, -Y, +Z
        .{ .{ -1, -1, 0 }, .{ 0, -1, 1 }, .{ -1, -1, 1 } },
        // v1 (minX, minY, minZ): corner at -X, -Y, -Z
        .{ .{ -1, -1, 0 }, .{ 0, -1, -1 }, .{ -1, -1, -1 } },
        // v2 (maxX, minY, minZ): corner at +X, -Y, -Z
        .{ .{ 1, -1, 0 }, .{ 0, -1, -1 }, .{ 1, -1, -1 } },
        // v3 (maxX, minY, maxZ): corner at +X, -Y, +Z
        .{ .{ 1, -1, 0 }, .{ 0, -1, 1 }, .{ 1, -1, 1 } },
    } };

    // UP face (Y+) - vertices order from FaceInfo:
    // v0: (minX, maxY, minZ), v1: (minX, maxY, maxZ), v2: (maxX, maxY, maxZ), v3: (maxX, maxY, minZ)
    // Face normal: (0, 1, 0)
    table[@intFromEnum(Direction.up)] = .{ .offsets = .{
        // v0 (minX, maxY, minZ): corner at -X, +Y, -Z
        .{ .{ -1, 1, 0 }, .{ 0, 1, -1 }, .{ -1, 1, -1 } },
        // v1 (minX, maxY, maxZ): corner at -X, +Y, +Z
        .{ .{ -1, 1, 0 }, .{ 0, 1, 1 }, .{ -1, 1, 1 } },
        // v2 (maxX, maxY, maxZ): corner at +X, +Y, +Z
        .{ .{ 1, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 } },
        // v3 (maxX, maxY, minZ): corner at +X, +Y, -Z
        .{ .{ 1, 1, 0 }, .{ 0, 1, -1 }, .{ 1, 1, -1 } },
    } };

    // NORTH face (Z-) - vertices order from FaceInfo:
    // v0: (maxX, maxY, minZ), v1: (maxX, minY, minZ), v2: (minX, minY, minZ), v3: (minX, maxY, minZ)
    // Face normal: (0, 0, -1)
    table[@intFromEnum(Direction.north)] = .{ .offsets = .{
        // v0 (maxX, maxY, minZ): corner at +X, +Y, -Z
        .{ .{ 1, 0, -1 }, .{ 0, 1, -1 }, .{ 1, 1, -1 } },
        // v1 (maxX, minY, minZ): corner at +X, -Y, -Z
        .{ .{ 1, 0, -1 }, .{ 0, -1, -1 }, .{ 1, -1, -1 } },
        // v2 (minX, minY, minZ): corner at -X, -Y, -Z
        .{ .{ -1, 0, -1 }, .{ 0, -1, -1 }, .{ -1, -1, -1 } },
        // v3 (minX, maxY, minZ): corner at -X, +Y, -Z
        .{ .{ -1, 0, -1 }, .{ 0, 1, -1 }, .{ -1, 1, -1 } },
    } };

    // SOUTH face (Z+) - vertices order from FaceInfo:
    // v0: (minX, maxY, maxZ), v1: (minX, minY, maxZ), v2: (maxX, minY, maxZ), v3: (maxX, maxY, maxZ)
    // Face normal: (0, 0, 1)
    table[@intFromEnum(Direction.south)] = .{ .offsets = .{
        // v0 (minX, maxY, maxZ): corner at -X, +Y, +Z
        .{ .{ -1, 0, 1 }, .{ 0, 1, 1 }, .{ -1, 1, 1 } },
        // v1 (minX, minY, maxZ): corner at -X, -Y, +Z
        .{ .{ -1, 0, 1 }, .{ 0, -1, 1 }, .{ -1, -1, 1 } },
        // v2 (maxX, minY, maxZ): corner at +X, -Y, +Z
        .{ .{ 1, 0, 1 }, .{ 0, -1, 1 }, .{ 1, -1, 1 } },
        // v3 (maxX, maxY, maxZ): corner at +X, +Y, +Z
        .{ .{ 1, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 } },
    } };

    // WEST face (X-) - vertices order from FaceInfo:
    // v0: (minX, maxY, minZ), v1: (minX, minY, minZ), v2: (minX, minY, maxZ), v3: (minX, maxY, maxZ)
    // Face normal: (-1, 0, 0)
    table[@intFromEnum(Direction.west)] = .{ .offsets = .{
        // v0 (minX, maxY, minZ): corner at -X, +Y, -Z
        .{ .{ -1, 1, 0 }, .{ -1, 0, -1 }, .{ -1, 1, -1 } },
        // v1 (minX, minY, minZ): corner at -X, -Y, -Z
        .{ .{ -1, -1, 0 }, .{ -1, 0, -1 }, .{ -1, -1, -1 } },
        // v2 (minX, minY, maxZ): corner at -X, -Y, +Z
        .{ .{ -1, -1, 0 }, .{ -1, 0, 1 }, .{ -1, -1, 1 } },
        // v3 (minX, maxY, maxZ): corner at -X, +Y, +Z
        .{ .{ -1, 1, 0 }, .{ -1, 0, 1 }, .{ -1, 1, 1 } },
    } };

    // EAST face (X+) - vertices order from FaceInfo:
    // v0: (maxX, maxY, maxZ), v1: (maxX, minY, maxZ), v2: (maxX, minY, minZ), v3: (maxX, maxY, minZ)
    // Face normal: (1, 0, 0)
    table[@intFromEnum(Direction.east)] = .{ .offsets = .{
        // v0 (maxX, maxY, maxZ): corner at +X, +Y, +Z
        .{ .{ 1, 1, 0 }, .{ 1, 0, 1 }, .{ 1, 1, 1 } },
        // v1 (maxX, minY, maxZ): corner at +X, -Y, +Z
        .{ .{ 1, -1, 0 }, .{ 1, 0, 1 }, .{ 1, -1, 1 } },
        // v2 (maxX, minY, minZ): corner at +X, -Y, -Z
        .{ .{ 1, -1, 0 }, .{ 1, 0, -1 }, .{ 1, -1, -1 } },
        // v3 (maxX, maxY, minZ): corner at +X, +Y, -Z
        .{ .{ 1, 1, 0 }, .{ 1, 0, -1 }, .{ 1, 1, -1 } },
    } };

    return table;
}

/// Calculate AO value for a single vertex
/// Returns an integer 0-3 where 0 = fully occluded, 3 = no occlusion
fn calculateVertexAo(side1: bool, side2: bool, corner: bool) u2 {
    // Convert booleans to integers (1 if solid, 0 if not)
    const s1: u2 = if (side1) 1 else 0;
    const s2: u2 = if (side2) 1 else 0;
    const c: u2 = if (corner) 1 else 0;

    // Minecraft's AO formula:
    // If both sides are solid, the corner is fully occluded (prevents light leaking)
    if (side1 and side2) {
        return 0;
    }
    // Otherwise, AO level is 3 minus the count of solid neighbors
    return 3 - (s1 + s2 + c);
}

/// Calculate AO brightness values for all 4 vertices of a face
/// Returns array of 4 brightness multipliers (0.2 to 1.0)
pub fn calculateFaceAo(
    chunk_access: *const ChunkAccess,
    block_x: i32,
    block_y: i32,
    block_z: i32,
    direction: Direction,
) [4]f32 {
    const neighbor_table = AO_NEIGHBOR_TABLE[@intFromEnum(direction)];
    var ao_values: [4]f32 = undefined;

    for (0..4) |vertex_idx| {
        const offsets = neighbor_table.offsets[vertex_idx];

        // Sample the 3 neighbor blocks
        const side1_solid = isBlockSolidForAo(chunk_access, block_x + offsets[0][0], block_y + offsets[0][1], block_z + offsets[0][2]);
        const side2_solid = isBlockSolidForAo(chunk_access, block_x + offsets[1][0], block_y + offsets[1][1], block_z + offsets[1][2]);
        const corner_solid = isBlockSolidForAo(chunk_access, block_x + offsets[2][0], block_y + offsets[2][1], block_z + offsets[2][2]);

        // Calculate AO level (0-3)
        const ao_level = calculateVertexAo(side1_solid, side2_solid, corner_solid);

        // Convert to brightness
        ao_values[vertex_idx] = AO_BRIGHTNESS[ao_level];
    }

    return ao_values;
}

/// Check if a block should be considered solid for AO purposes
fn isBlockSolidForAo(chunk_access: *const ChunkAccess, x: i32, y: i32, z: i32) bool {
    const entry = chunk_access.getBlockEntry(x, y, z);
    // Use opacity for AO (transparent blocks don't cast AO shadows)
    return entry.isOpaque();
}

/// Apply AO values to vertex colors
/// Takes base color and 4 AO values, returns 4 modified colors
pub fn applyAoToColors(base_color: [3]f32, ao_values: [4]f32) [4][3]f32 {
    var colors: [4][3]f32 = undefined;
    for (0..4) |i| {
        colors[i] = .{
            base_color[0] * ao_values[i],
            base_color[1] * ao_values[i],
            base_color[2] * ao_values[i],
        };
    }
    return colors;
}

/// Check if AO quad needs to be flipped for correct interpolation
/// Returns true if vertices should be rotated to fix anisotropic lighting artifacts
pub fn shouldFlipQuad(ao_values: [4]f32) bool {
    // Compare diagonals to determine which way to flip
    // If v0+v2 < v1+v3, flip the quad to get better interpolation
    return (ao_values[0] + ao_values[2]) < (ao_values[1] + ao_values[3]);
}
