const std = @import("std");
const storage_types = @import("types.zig");
const WorldState = @import("../WorldState.zig");

const ChunkKey = storage_types.ChunkKey;
const Chunk = WorldState.Chunk;

const CACHE_SLOTS = 4096;

/// In-memory cache of decompressed chunks using CLOCK eviction.
/// Returns direct pointers into the cache array — zero-copy for callers.
/// Thread-safe via mutex.
pub const ChunkCache = struct {
    mutex: std.Thread.Mutex,
    slots: [CACHE_SLOTS]Slot,
    clock_hand: u32,
    count: u32,

    const Slot = struct {
        key: ChunkKey,
        chunk: Chunk,
        valid: bool,
        referenced: bool,
    };

    pub fn init() ChunkCache {
        var cache: ChunkCache = .{
            .mutex = .{},
            .slots = undefined,
            .clock_hand = 0,
            .count = 0,
        };
        for (&cache.slots) |*slot| {
            slot.valid = false;
            slot.referenced = false;
        }
        return cache;
    }

    /// Look up a chunk in the cache by key.
    /// Returns a pointer directly into the cache slot (zero-copy).
    /// The pointer remains valid until the slot is evicted.
    pub fn get(self: *ChunkCache, key: ChunkKey) ?*const Chunk {
        self.mutex.lock();
        defer self.mutex.unlock();

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
    /// If the cache is full, a slot is evicted using CLOCK.
    pub fn put(self: *ChunkCache, key: ChunkKey, chunk: *const Chunk) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already present
        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) break; // Not found
            if (slot.key.eql(key)) {
                // Update existing
                slot.chunk = chunk.*;
                slot.referenced = true;
                return;
            }
        }

        // Not found — evict a slot if needed and insert
        const target = self.findEvictSlot();
        if (self.slots[target].valid) {
            // We're evicting
        } else {
            self.count += 1;
        }

        self.slots[target] = .{
            .key = key,
            .chunk = chunk.*,
            .valid = true,
            .referenced = true,
        };
    }

    /// Invalidate a specific cache entry.
    pub fn invalidate(self: *ChunkCache, key: ChunkKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const start = self.hashSlot(key);
        var probe: u32 = 0;
        while (probe < CACHE_SLOTS) : (probe += 1) {
            const idx = (start + probe) % CACHE_SLOTS;
            const slot = &self.slots[idx];
            if (!slot.valid) return;
            if (slot.key.eql(key)) {
                slot.valid = false;
                self.count -= 1;
                return;
            }
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
