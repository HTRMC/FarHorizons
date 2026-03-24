const std = @import("std");
const WorldState = @import("WorldState.zig");
const Chunk = WorldState.Chunk;
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;
const BlockState = @import("BlockState.zig");
const Io = std.Io;

pub const ChunkPool = struct {
    free_list: std.ArrayList(*Chunk),
    allocator: std.mem.Allocator,
    mutex: Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) ChunkPool {
        return .{
            .free_list = .empty,
            .allocator = allocator,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *ChunkPool) void {
        for (self.free_list.items) |chunk| {
            chunk.blocks.deinit();
            self.allocator.destroy(chunk);
        }
        self.free_list.deinit(self.allocator);
    }

    pub fn acquire(self: *ChunkPool) *Chunk {
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        const result = if (self.free_list.items.len > 0)
            self.free_list.pop().?
        else
            null;
        self.mutex.unlock(io);

        if (result) |chunk| {
            chunk.blocks.fillUniform(0);
            return chunk;
        }

        const chunk = self.allocator.create(Chunk) catch @panic("ChunkPool: out of memory");
        chunk.blocks = WorldState.PaletteBlocks.init(self.allocator);
        return chunk;
    }

    pub fn release(self: *ChunkPool, chunk: *Chunk) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.free_list.append(self.allocator, chunk) catch {
            self.mutex.unlock(io);
            chunk.blocks.deinit();
            self.allocator.destroy(chunk);
            return;
        };
        self.mutex.unlock(io);
    }
};
