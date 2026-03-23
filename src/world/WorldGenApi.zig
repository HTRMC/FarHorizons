//! EXE-side loader for the worldgen DLL.
//! Provides the same API surface as direct TerrainGen calls.
//! Falls back to direct (statically linked) calls if the DLL is not found.

const std = @import("std");
const WorldGenTypes = @import("WorldGenTypes.zig");
const Chunk = WorldGenTypes.Chunk;
const ChunkKey = WorldGenTypes.ChunkKey;

const win32 = struct {
    const HMODULE = *opaque {};
    const FARPROC = *const fn () callconv(.c) isize;
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?HMODULE;
    extern "kernel32" fn FreeLibrary(h: HMODULE) callconv(.c) c_int;
    extern "kernel32" fn GetProcAddress(h: HMODULE, name: [*:0]const u8) callconv(.c) ?FARPROC;
};

const GenerateChunkFn = *const fn (*Chunk, i32, i32, i32, u64) callconv(.c) void;
const GenerateLodChunkFn = *const fn (*Chunk, i32, i32, i32, u64, u32) callconv(.c) void;
const SampleHeightFn = *const fn (i32, i32, u64) callconv(.c) i32;

var generate_chunk_fn: ?GenerateChunkFn = null;
var generate_lod_chunk_fn: ?GenerateLodChunkFn = null;
var sample_height_fn: ?SampleHeightFn = null;
var sample_grid_height_fn: ?SampleHeightFn = null;
var dll_handle: ?win32.HMODULE = null;

const log = std.log.scoped(.worldgen);

fn lookup(comptime T: type, handle: win32.HMODULE, name: [*:0]const u8) ?T {
    const addr = win32.GetProcAddress(handle, name) orelse return null;
    return @ptrCast(addr);
}

pub fn init() void {
    const handle = win32.LoadLibraryA("worldgen.dll") orelse {
        log.warn("worldgen.dll not found, using static fallback", .{});
        return;
    };
    dll_handle = handle;

    generate_chunk_fn = lookup(GenerateChunkFn, handle, "wg_generateChunk");
    generate_lod_chunk_fn = lookup(GenerateLodChunkFn, handle, "wg_generateLodChunk");
    sample_height_fn = lookup(SampleHeightFn, handle, "wg_sampleHeight");
    sample_grid_height_fn = lookup(SampleHeightFn, handle, "wg_sampleGridHeight");

    if (generate_chunk_fn != null and generate_lod_chunk_fn != null and
        sample_height_fn != null and sample_grid_height_fn != null)
    {
        log.info("worldgen.dll loaded", .{});
    } else {
        log.warn("worldgen.dll loaded but missing symbols, using static fallback", .{});
    }
}

pub fn deinit() void {
    if (dll_handle) |h| {
        _ = win32.FreeLibrary(h);
        dll_handle = null;
    }
}

// --- Direct fallback imports (used when DLL is absent) ---
const TerrainGen = @import("TerrainGen.zig");

pub fn generateChunk(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    if (generate_chunk_fn) |f| {
        f(chunk, key.cx, key.cy, key.cz, seed);
    } else {
        TerrainGen.generateChunk(chunk, key, seed);
    }
}

pub fn generateLodChunk(chunk: *Chunk, key: ChunkKey, seed: u64, voxel_size: u32) void {
    if (generate_lod_chunk_fn) |f| {
        f(chunk, key.cx, key.cy, key.cz, seed, voxel_size);
    } else {
        TerrainGen.generateLodChunk(chunk, key, seed, voxel_size);
    }
}

pub fn sampleHeight(wx: i32, wz: i32, seed: u64) i32 {
    if (sample_height_fn) |f| {
        return f(wx, wz, seed);
    }
    return TerrainGen.sampleHeight(wx, wz, seed);
}

pub fn sampleGridHeight(wx: i32, wz: i32, seed: u64) i32 {
    if (sample_grid_height_fn) |f| {
        return f(wx, wz, seed);
    }
    return TerrainGen.sampleGridHeight(wx, wz, seed);
}
