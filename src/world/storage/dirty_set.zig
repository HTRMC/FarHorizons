const std = @import("std");
const storage_types = @import("types.zig");
const WorldState = @import("../WorldState.zig");
const GameChunkPool = @import("../ChunkPool.zig").ChunkPool;

const Io = std.Io;

const ChunkKey = storage_types.ChunkKey;
const RegionCoord = storage_types.RegionCoord;
const Chunk = WorldState.Chunk;

const log = std.log.scoped(.dirty_set);

const c_time = struct {
    extern "c" fn time(timer: ?*i64) i64;
};

fn now() i64 {
    return c_time.time(null);
}

pub const UrgencyTier = enum(u3) {
    critical = 0,
    urgent = 1,
    normal = 2,
    deferred = 3,
};

pub const DirtyEntry = struct {
    key: ChunkKey,
    region_coord: RegionCoord,
    first_dirty_time: i64,
    last_dirty_time: i64,
    chunk: *Chunk,

    pub fn computeUrgency(self: *const DirtyEntry, current_time: i64) UrgencyTier {
        const dirty_duration = current_time - self.first_dirty_time;
        const idle_duration = current_time - self.last_dirty_time;

        if (dirty_duration > 30) return .urgent;
        if (dirty_duration > 5 and idle_duration > 2) return .normal;
        return .deferred;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeDummyEntry(first_dirty: i64, last_dirty: i64) DirtyEntry {
    return .{
        .key = .{ .cx = 0, .cy = 0, .cz = 0 },
        .region_coord = .{ .rx = 0, .rz = 0 },
        .first_dirty_time = first_dirty,
        .last_dirty_time = last_dirty,
        .chunk = undefined,
    };
}

test "computeUrgency: deferred when freshly dirtied" {
    const entry = makeDummyEntry(100, 100);
    try testing.expectEqual(UrgencyTier.deferred, entry.computeUrgency(100));
    try testing.expectEqual(UrgencyTier.deferred, entry.computeUrgency(101));
}

test "computeUrgency: deferred when dirty < 5s" {
    const entry = makeDummyEntry(100, 100);
    try testing.expectEqual(UrgencyTier.deferred, entry.computeUrgency(105));
}

test "computeUrgency: normal when dirty > 5s and idle > 2s" {
    const entry = makeDummyEntry(100, 100);
    // dirty_duration=6 > 5, idle_duration=6 > 2
    try testing.expectEqual(UrgencyTier.normal, entry.computeUrgency(106));
}

test "computeUrgency: deferred when dirty > 5s but idle <= 2s" {
    // first_dirty=100, last_dirty=108, current=110
    // dirty_duration=10 > 5, idle_duration=2 — NOT > 2
    const entry = makeDummyEntry(100, 108);
    try testing.expectEqual(UrgencyTier.deferred, entry.computeUrgency(110));
}

test "computeUrgency: urgent when dirty > 30s" {
    const entry = makeDummyEntry(100, 130);
    // dirty_duration=31 > 30
    try testing.expectEqual(UrgencyTier.urgent, entry.computeUrgency(131));
}

test "computeUrgency: urgent overrides normal" {
    // dirty_duration=31 > 30 → urgent even though idle is also > 2
    const entry = makeDummyEntry(100, 100);
    try testing.expectEqual(UrgencyTier.urgent, entry.computeUrgency(131));
}

test "computeUrgency: boundary at exactly 30s is deferred (not urgent)" {
    // dirty_duration = 30, which is NOT > 30
    const entry = makeDummyEntry(100, 100);
    // dirty=30, idle=30 → not urgent (30 is not > 30), but dirty>5 and idle>2 → normal
    try testing.expectEqual(UrgencyTier.normal, entry.computeUrgency(130));
}

test "computeUrgency: boundary at exactly 5s dirty, 2s idle is deferred" {
    // dirty_duration=5, NOT > 5
    const entry = makeDummyEntry(100, 103);
    // current=105: dirty=5 (not >5), so → deferred
    try testing.expectEqual(UrgencyTier.deferred, entry.computeUrgency(105));
}

pub const UrgencyCounts = struct {
    critical: u32 = 0,
    urgent: u32 = 0,
    normal: u32 = 0,
    deferred: u32 = 0,
};

pub const MAX_BATCH_SIZE = 20;

pub const RegionBatch = struct {
    region_coord: RegionCoord,
    count: u32,
    indices: [MAX_BATCH_SIZE]u9,
    keys: [MAX_BATCH_SIZE]ChunkKey,
    chunks: [MAX_BATCH_SIZE]*Chunk,
};

pub const DrainResult = struct {
    batches: [MAX_BATCH_SIZE]RegionBatch,
    batch_count: u32,
    total_drained: u32,
};

pub const DirtySet = struct {
    map: std.AutoHashMap(u64, DirtyEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !DirtySet {
        var map = std.AutoHashMap(u64, DirtyEntry).init(allocator);
        try map.ensureTotalCapacity(256);
        return .{
            .map = map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DirtySet, chunk_pool: *GameChunkPool) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            chunk_pool.release(entry.chunk);
        }
        self.map.deinit();
    }

    /// Mark a chunk as dirty. Increments the chunk's ref_count so it
    /// stays alive until the dirty set releases it (after IO save).
    pub fn markDirty(self: *DirtySet, key: ChunkKey, chunk: *Chunk, chunk_pool: *GameChunkPool) void {
        const k = key.toU64();
        const current_time = now();

        if (self.map.getPtr(k)) |existing| {
            existing.last_dirty_time = current_time;
            if (existing.chunk != chunk) {
                // Chunk was unloaded and reloaded at same position — swap refs
                chunk_pool.release(existing.chunk);
                _ = chunk.ref_count.fetchAdd(1, .acq_rel);
                existing.chunk = chunk;
            }
            return;
        }

        // Acquire a reference for the dirty set
        _ = chunk.ref_count.fetchAdd(1, .acq_rel);

        self.map.put(k, .{
            .key = key,
            .region_coord = key.regionCoord(),
            .first_dirty_time = current_time,
            .last_dirty_time = current_time,
            .chunk = chunk,
        }) catch {
            // Failed to insert — release the ref we just acquired
            chunk_pool.release(chunk);
            log.err("Failed to insert dirty entry", .{});
        };
    }

    pub fn remove(self: *DirtySet, key: ChunkKey, chunk_pool: *GameChunkPool) void {
        const k = key.toU64();
        if (self.map.fetchRemove(k)) |kv| {
            chunk_pool.release(kv.value.chunk);
        }
    }

    pub fn count(self: *const DirtySet) u32 {
        return @intCast(self.map.count());
    }

    pub fn urgencyCounts(self: *const DirtySet) UrgencyCounts {
        var counts = UrgencyCounts{};
        const current_time = now();
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            switch (entry.computeUrgency(current_time)) {
                .critical => counts.critical += 1,
                .urgent => counts.urgent += 1,
                .normal => counts.normal += 1,
                .deferred => counts.deferred += 1,
            }
        }
        return counts;
    }

    /// Drain up to `budget` dirty chunks, grouped by region.
    /// Transfers ownership of chunk references to the returned batches.
    pub fn drainBatch(self: *DirtySet, budget: u32) ?DrainResult {
        const effective_budget = @min(budget, MAX_BATCH_SIZE);
        if (self.map.count() == 0) return null;

        const current_time = now();

        var candidates: [MAX_BATCH_SIZE]struct { key_u64: u64, urgency: u3, region_hash: u64 } = undefined;
        var candidate_count: u32 = 0;

        var it = self.map.iterator();
        while (it.next()) |kv| {
            const urgency = kv.value_ptr.computeUrgency(current_time);
            if (urgency == .deferred and candidate_count >= effective_budget) continue;

            if (candidate_count < effective_budget) {
                candidates[candidate_count] = .{
                    .key_u64 = kv.key_ptr.*,
                    .urgency = @intFromEnum(urgency),
                    .region_hash = kv.value_ptr.region_coord.hash(),
                };
                candidate_count += 1;
            } else {
                var worst_idx: u32 = 0;
                for (1..candidate_count) |i| {
                    if (candidates[i].urgency > candidates[worst_idx].urgency) {
                        worst_idx = @intCast(i);
                    }
                }
                if (@intFromEnum(urgency) < candidates[worst_idx].urgency) {
                    candidates[worst_idx] = .{
                        .key_u64 = kv.key_ptr.*,
                        .urgency = @intFromEnum(urgency),
                        .region_hash = kv.value_ptr.region_coord.hash(),
                    };
                }
            }
        }

        if (candidate_count == 0) return null;

        std.mem.sort(
            @TypeOf(candidates[0]),
            candidates[0..candidate_count],
            {},
            struct {
                fn lessThan(_: void, a: @TypeOf(candidates[0]), b: @TypeOf(candidates[0])) bool {
                    if (a.urgency != b.urgency) return a.urgency < b.urgency;
                    return a.region_hash < b.region_hash;
                }
            }.lessThan,
        );

        var result = DrainResult{
            .batches = undefined,
            .batch_count = 0,
            .total_drained = 0,
        };

        for (0..candidate_count) |i| {
            const key_u64 = candidates[i].key_u64;
            const entry = self.map.get(key_u64) orelse continue;

            var batch_idx: ?u32 = null;
            for (0..result.batch_count) |bi| {
                if (result.batches[bi].region_coord.eql(entry.region_coord)) {
                    batch_idx = @intCast(bi);
                    break;
                }
            }

            if (batch_idx == null) {
                if (result.batch_count >= MAX_BATCH_SIZE) continue;
                batch_idx = result.batch_count;
                result.batches[result.batch_count] = .{
                    .region_coord = entry.region_coord,
                    .count = 0,
                    .indices = std.mem.zeroes([MAX_BATCH_SIZE]u9),
                    .keys = std.mem.zeroes([MAX_BATCH_SIZE]ChunkKey),
                    .chunks = undefined,
                };
                result.batch_count += 1;
            }

            const bi = batch_idx.?;
            const ci = result.batches[bi].count;
            if (ci >= MAX_BATCH_SIZE) continue;

            result.batches[bi].indices[ci] = entry.key.localIndex();
            result.batches[bi].keys[ci] = entry.key;
            result.batches[bi].chunks[ci] = entry.chunk;
            result.batches[bi].count += 1;
            result.total_drained += 1;

            // Remove from map — ownership of the ref transfers to the batch
            _ = self.map.remove(key_u64);
        }

        return result;
    }
};
