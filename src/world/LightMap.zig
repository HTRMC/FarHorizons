const std = @import("std");
const WorldState = @import("WorldState.zig");
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;
const PaletteStorage = @import("../allocators/PaletteStorage.zig").PaletteStorage;
const Io = std.Io;

pub const BlockLightStorage = PaletteStorage([3]u8, BLOCKS_PER_CHUNK);
pub const SkyLightStorage = PaletteStorage(u8, BLOCKS_PER_CHUNK);

pub const LightMap = struct {
    block_light: BlockLightStorage,
    sky_light: SkyLightStorage,
    dirty: bool,
    mutex: Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator) LightMap {
        return .{
            .block_light = BlockLightStorage.init(allocator),
            .sky_light = SkyLightStorage.init(allocator),
            .dirty = true,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *LightMap) void {
        self.block_light.deinit();
        self.sky_light.deinit();
    }

    pub fn clear(self: *LightMap) void {
        self.block_light.fillUniform(.{ 0, 0, 0 });
        self.sky_light.fillUniform(0);
        self.dirty = true;
    }
};

const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const BORDER_SIZE = CHUNK_SIZE * CHUNK_SIZE;

/// Snapshot of one neighbor face's boundary light values.
/// Copied under brief lock so mesh/light workers can read without holding
/// the neighbor's mutex for the entire operation.
pub const LightBorderSnapshot = struct {
    sky: [BORDER_SIZE]u8,
    block: [BORDER_SIZE][3]u8,
    valid: bool,

    pub const empty: LightBorderSnapshot = .{
        .sky = .{0} ** BORDER_SIZE,
        .block = .{.{ 0, 0, 0 }} ** BORDER_SIZE,
        .valid = false,
    };

    /// Get sky light at the given 2D border index.
    pub fn getSky(self: *const LightBorderSnapshot, idx: usize) u8 {
        return self.sky[idx];
    }

    /// Get block light at the given 2D border index.
    pub fn getBlock(self: *const LightBorderSnapshot, idx: usize) [3]u8 {
        return self.block[idx];
    }
};

/// Snapshot the 6 neighbor faces from their LightMaps, locking each briefly.
/// Each face reads the boundary slice that faces the center chunk.
/// Face mapping:
///   0 (+Z): neighbor's z=0      1 (-Z): neighbor's z=31
///   2 (-X): neighbor's x=31     3 (+X): neighbor's x=0
///   4 (+Y): neighbor's y=0      5 (-Y): neighbor's y=31
pub fn snapshotNeighborBorders(
    neighbor_lights: [6]?*const LightMap,
) [6]LightBorderSnapshot {
    const io = Io.Threaded.global_single_threaded.io();
    var borders: [6]LightBorderSnapshot = .{LightBorderSnapshot.empty} ** 6;

    for (0..6) |face| {
        const lm_const = neighbor_lights[face] orelse continue;
        // Cast away const to access the mutex (mutex is logically separate from data)
        const lm: *LightMap = @constCast(lm_const);

        lm.mutex.lockUncancelable(io);
        defer lm.mutex.unlock(io);

        if (lm.dirty) continue; // Skip dirty — data is stale

        var idx: usize = 0;
        switch (face) {
            0 => { // +Z: neighbor's z=0
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        const ci = WorldState.chunkIndex(x, y, 0);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            1 => { // -Z: neighbor's z=31
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        const ci = WorldState.chunkIndex(x, y, CHUNK_SIZE - 1);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            2 => { // -X: neighbor's x=31
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        const ci = WorldState.chunkIndex(CHUNK_SIZE - 1, y, z);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            3 => { // +X: neighbor's x=0
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        const ci = WorldState.chunkIndex(0, y, z);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            4 => { // +Y: neighbor's y=0
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        const ci = WorldState.chunkIndex(x, 0, z);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            5 => { // -Y: neighbor's y=31
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        const ci = WorldState.chunkIndex(x, CHUNK_SIZE - 1, z);
                        borders[face].sky[idx] = lm.sky_light.get(ci);
                        borders[face].block[idx] = lm.block_light.get(ci);
                        idx += 1;
                    }
                }
            },
            else => unreachable,
        }
        borders[face].valid = true;
    }

    return borders;
}

pub const LightMapPool = struct {
    free_list: std.ArrayList(*LightMap),
    allocator: std.mem.Allocator,
    mutex: Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) LightMapPool {
        return .{
            .free_list = .empty,
            .allocator = allocator,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *LightMapPool) void {
        for (self.free_list.items) |lm| {
            lm.deinit();
            self.allocator.destroy(lm);
        }
        self.free_list.deinit(self.allocator);
    }

    pub fn acquire(self: *LightMapPool) *LightMap {
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        const result = if (self.free_list.items.len > 0)
            self.free_list.pop().?
        else
            null;
        self.mutex.unlock(io);

        if (result) |lm| {
            lm.clear();
            return lm;
        }

        const lm = self.allocator.create(LightMap) catch @panic("LightMapPool: out of memory");
        lm.* = LightMap.init(self.allocator);
        return lm;
    }

    pub fn release(self: *LightMapPool, lm: *LightMap) void {
        // Shrink to minimal footprint while pooled
        lm.clear();
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.free_list.append(self.allocator, lm) catch {
            self.mutex.unlock(io);
            lm.deinit();
            self.allocator.destroy(lm);
            return;
        };
        self.mutex.unlock(io);
    }
};
