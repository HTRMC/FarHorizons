//! EXE-side loader for the worldgen DLL.
//! The DLL must be present — the game will not start without it.

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

var generate_chunk_fn: GenerateChunkFn = undefined;
var generate_lod_chunk_fn: GenerateLodChunkFn = undefined;
var sample_height_fn: SampleHeightFn = undefined;
var sample_grid_height_fn: SampleHeightFn = undefined;
var dll_handle: ?win32.HMODULE = null;

const log = std.log.scoped(.worldgen);

fn lookupRequired(comptime T: type, handle: win32.HMODULE, comptime name: [:0]const u8) T {
    const addr = win32.GetProcAddress(handle, name.ptr) orelse
        @panic("worldgen.dll: missing symbol " ++ name);
    return @ptrCast(addr);
}

pub fn init() void {
    const handle = win32.LoadLibraryA("worldgen.dll") orelse
        @panic("worldgen.dll not found — run 'zig build' to produce it");
    dll_handle = handle;

    generate_chunk_fn = lookupRequired(GenerateChunkFn, handle, "wg_generateChunk");
    generate_lod_chunk_fn = lookupRequired(GenerateLodChunkFn, handle, "wg_generateLodChunk");
    sample_height_fn = lookupRequired(SampleHeightFn, handle, "wg_sampleHeight");
    sample_grid_height_fn = lookupRequired(SampleHeightFn, handle, "wg_sampleGridHeight");

    log.info("worldgen.dll loaded", .{});
}

pub fn deinit() void {
    if (dll_handle) |h| {
        _ = win32.FreeLibrary(h);
        dll_handle = null;
    }
}

pub fn generateChunk(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    generate_chunk_fn(chunk, key.cx, key.cy, key.cz, seed);
}

pub fn generateLodChunk(chunk: *Chunk, key: ChunkKey, seed: u64, voxel_size: u32) void {
    generate_lod_chunk_fn(chunk, key.cx, key.cy, key.cz, seed, voxel_size);
}

pub fn sampleHeight(wx: i32, wz: i32, seed: u64) i32 {
    return sample_height_fn(wx, wz, seed);
}

pub fn sampleGridHeight(wx: i32, wz: i32, seed: u64) i32 {
    return sample_grid_height_fn(wx, wz, seed);
}
