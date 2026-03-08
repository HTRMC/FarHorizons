const std = @import("std");
const WorldState = @import("WorldState.zig");
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;
const Io = std.Io;

pub const LightMap = struct {
    block_light: [BLOCKS_PER_CHUNK][3]u8,
    sky_light: [BLOCKS_PER_CHUNK]u8,
    dirty: bool,

    pub fn clear(self: *LightMap) void {
        @memset(std.mem.asBytes(&self.block_light), 0);
        @memset(&self.sky_light, 0);
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
        lm.clear();
        return lm;
    }

    pub fn release(self: *LightMapPool, lm: *LightMap) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.free_list.append(self.allocator, lm) catch {
            self.mutex.unlock(io);
            self.allocator.destroy(lm);
            return;
        };
        self.mutex.unlock(io);
    }
};
