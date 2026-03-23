//! Worldgen DLL — exports C-ABI functions for terrain generation.
//! Built as a shared library for fast incremental rebuilds.

const WorldGenTypes = @import("world/WorldGenTypes.zig");
const TerrainGen = @import("world/TerrainGen.zig");
const Chunk = WorldGenTypes.Chunk;

export fn wg_generateChunk(chunk: *Chunk, cx: i32, cy: i32, cz: i32, seed: u64) callconv(.c) void {
    TerrainGen.generateChunk(chunk, .{ .cx = cx, .cy = cy, .cz = cz }, seed);
}

export fn wg_generateLodChunk(chunk: *Chunk, cx: i32, cy: i32, cz: i32, seed: u64, voxel_size: u32) callconv(.c) void {
    TerrainGen.generateLodChunk(chunk, .{ .cx = cx, .cy = cy, .cz = cz }, seed, voxel_size);
}

export fn wg_sampleHeight(wx: i32, wz: i32, seed: u64) callconv(.c) i32 {
    return TerrainGen.sampleHeight(wx, wz, seed);
}

export fn wg_sampleGridHeight(wx: i32, wz: i32, seed: u64) callconv(.c) i32 {
    return TerrainGen.sampleGridHeight(wx, wz, seed);
}
