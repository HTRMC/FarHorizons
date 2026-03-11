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
