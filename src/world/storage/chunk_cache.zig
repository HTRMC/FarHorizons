const std = @import("std");
const storage_types = @import("types.zig");
const WorldState = @import("../WorldState.zig");

const ChunkKey = storage_types.ChunkKey;
const Chunk = WorldState.Chunk;
const Io = std.Io;

const CACHE_SLOTS = 4096;

/// In-memory cache of decompressed chunks using CLOCK eviction.
/// Returns direct pointers into the cache array — zero-copy for callers.
/// Thread-safe via mutex.
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

    /// Look up a chunk in the cache by key.
    /// Returns a pointer directly into the cache slot (zero-copy).
    /// The pointer remains valid until the slot is evicted.
    pub fn get(self: *ChunkCache, key: ChunkKey) ?*const Chunk {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) return null; // Empty slot — key not in cache
            if (slot.key.eql(key)) {
                slot.referenced = true;
                return &slot.chunk;
            }
        }
        return null;
    }

    /// Insert a chunk into the cache.
    /// If the key already exists, the data is updated.
    /// If the probe chain has an empty slot, insert there directly.
    /// If the chain is full, evict a slot using CLOCK within the chain.
    pub fn put(self: *ChunkCache, key: ChunkKey, chunk: *const Chunk) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check if already present, or find the first empty slot in the chain
        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) {
                // Empty slot at end of probe chain — insert here
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
                // Update existing
                slot.chunk = chunk.*;
                slot.referenced = true;
                return;
            }
        }

        // Probe chain is full — evict using CLOCK and insert at evicted slot
        const target = self.findEvictSlot();
        self.slots[target] = .{
            .key = key,
            .chunk = chunk.*,
            .valid = true,
            .referenced = true,
        };
    }

    /// Invalidate a specific cache entry.
    /// Uses backward-shift deletion to maintain probe chain integrity.
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
                // Found it — backward-shift delete to preserve probe chains
                self.count -= 1;
                var empty = idx;
                var j: u32 = 1;
                while (j < CACHE_SLOTS) : (j += 1) {
                    const next = (idx + j) % CACHE_SLOTS;
                    if (!self.slots[next].valid) break;
                    const natural = self.hashSlot(self.slots[next].key);
                    // Check if `next` belongs at or before `empty` in the probe chain
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

    /// Helper for backward-shift deletion: determines if an entry at `current`
    /// with natural hash position `natural` should be shifted to fill `empty`.
    fn shouldShift(_: *ChunkCache, natural: u32, empty: u32, current: u32) bool {
        // In a circular buffer, entry should shift if `empty` is between
        // `natural` and `current` (wrapping around).
        if (empty <= current) {
            return natural <= empty or natural > current;
        } else {
            return natural <= empty and natural > current;
        }
    }

    /// CLOCK eviction: scan from clock_hand, give unreferenced slots a second chance.
    fn findEvictSlot(self: *ChunkCache) u32 {
        var scans: u32 = 0;
        while (scans < CACHE_SLOTS * 2) : (scans += 1) {
            const idx = self.clock_hand;
            self.clock_hand = (self.clock_hand + 1) % CACHE_SLOTS;

            const slot = &self.slots[idx];
            if (!slot.valid) return idx;
            if (!slot.referenced) return idx;
            slot.referenced = false; // Give a second chance
        }
        // Fallback: evict clock hand
        const idx = self.clock_hand;
        self.clock_hand = (self.clock_hand + 1) % CACHE_SLOTS;
        return idx;
    }

    /// Hash a ChunkKey to a slot index.
    fn hashSlot(_: *const ChunkCache, key: ChunkKey) u32 {
        const raw = key.toU64();
        // FNV-1a inspired mixing
        var h: u64 = raw;
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        h *%= 0xc4ceb9fe1a85ec53;
        h ^= h >> 33;
        return @intCast(h % CACHE_SLOTS);
    }
};
