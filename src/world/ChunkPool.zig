const std = @import("std");
const WorldState = @import("WorldState.zig");
const Chunk = WorldState.Chunk;
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;

pub const ChunkPool = struct {
    free_list: std.ArrayList(*Chunk),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChunkPool {
        return .{
            .free_list = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChunkPool) void {
        for (self.free_list.items) |chunk| {
            self.allocator.destroy(chunk);
        }
        self.free_list.deinit(self.allocator);
    }

    pub fn acquire(self: *ChunkPool) *Chunk {
        if (self.free_list.items.len > 0) {
            return self.free_list.pop().?;
        }
        const chunk = self.allocator.create(Chunk) catch @panic("ChunkPool: out of memory");
        chunk.blocks = .{.air} ** BLOCKS_PER_CHUNK;
        return chunk;
    }

    pub fn release(self: *ChunkPool, chunk: *Chunk) void {
        chunk.blocks = .{.air} ** BLOCKS_PER_CHUNK;
        self.free_list.append(self.allocator, chunk) catch {
            self.allocator.destroy(chunk);
        };
    }
};
