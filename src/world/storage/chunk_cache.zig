const std = @import("std");
const storage_types = @import("types.zig");
const WorldState = @import("../WorldState.zig");

const ChunkKey = storage_types.ChunkKey;
const Chunk = WorldState.Chunk;
const Io = std.Io;

const CACHE_SLOTS = 4096;

pub const ChunkCache = struct {
    mutex: Io.Mutex,
    io: Io,
    slots: [CACHE_SLOTS]Slot,
    clock_hand: u32,
    count: u32,

    const Slot = struct {
        key: ChunkKey,
        chunk: Chunk,
        valid: bool,
        referenced: bool,
    };

    pub fn initInPlace(self: *ChunkCache) void {
        self.mutex = .init;
        self.io = Io.Threaded.global_single_threaded.io();
        self.clock_hand = 0;
        self.count = 0;
        for (&self.slots) |*slot| {
            slot.valid = false;
            slot.referenced = false;
        }
    }

    pub fn get(self: *ChunkCache, key: ChunkKey) ?*const Chunk {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) return null;
            if (slot.key.eql(key)) {
                slot.referenced = true;
                return &slot.chunk;
            }
        }
        return null;
    }

    pub fn put(self: *ChunkCache, key: ChunkKey, chunk: *const Chunk) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) {
                slot.* = .{
                    .key = key,
                    .chunk = chunk.*,
                    .valid = true,
                    .referenced = true,
                };
                self.count += 1;
                return;
            }
            if (slot.key.eql(key)) {
                slot.chunk = chunk.*;
                slot.referenced = true;
                return;
            }
        }

        const target = self.findEvictSlot();
        self.slots[target] = .{
            .key = key,
            .chunk = chunk.*,
            .valid = true,
            .referenced = true,
        };
    }

    pub fn invalidate(self: *ChunkCache, key: ChunkKey) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) return;
            if (slot.key.eql(key)) {
                self.count -= 1;
                var empty = idx;
                var j: u32 = 1;
                while (j < CACHE_SLOTS) : (j += 1) {
                    const next = (idx + j) % CACHE_SLOTS;
                    if (!self.slots[next].valid) break;
                    const natural = self.hashSlot(self.slots[next].key);
                    if (self.shouldShift(natural, empty, next)) {
                        self.slots[empty] = self.slots[next];
                        empty = next;
                    }
                }
                self.slots[empty].valid = false;
                return;
            }
        }
    }

    fn shouldShift(_: *ChunkCache, natural: u32, empty: u32, current: u32) bool {
        if (empty <= current) {
            return natural <= empty or natural > current;
        } else {
            return natural <= empty and natural > current;
        }
    }

    fn findEvictSlot(self: *ChunkCache) u32 {
        var scans: u32 = 0;
        while (scans < CACHE_SLOTS * 2) : (scans += 1) {
            const idx = self.clock_hand;
            self.clock_hand = (self.clock_hand + 1) % CACHE_SLOTS;

            const slot = &self.slots[idx];
            if (!slot.valid) return idx;
            if (!slot.referenced) return idx;
            slot.referenced = false;
        }
        const idx = self.clock_hand;
        self.clock_hand = (self.clock_hand + 1) % CACHE_SLOTS;
        return idx;
    }

    fn hashSlot(_: *const ChunkCache, key: ChunkKey) u32 {
        const raw = key.toU64();
        var h: u64 = raw;
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        h *%= 0xc4ceb9fe1a85ec53;
        h ^= h >> 33;
        return @intCast(h % CACHE_SLOTS);
    }
};
