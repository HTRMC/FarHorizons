/// Epoch-based Read-Copy-Update (RCU) implementation
/// Provides near-zero overhead read-side synchronization for concurrent data access.
///
/// How it works:
/// - Readers enter/exit "critical sections" by announcing their current epoch
/// - Writers defer deletion until all readers have exited the epoch where deletion occurred
/// - Grace period detection: items deleted in epoch N are freed when all threads reach epoch N+2
///
/// Performance characteristics:
/// - Read-side: Single atomic load (acquire) + single atomic store (release)
/// - Write-side: Deferred freeing, batched per epoch
/// - No locks, no contention between readers
///
/// Usage:
/// ```
/// // Reader (worker thread):
/// const guard = rcu.readLock(thread_id);
/// defer rcu.readUnlock(thread_id);
/// // ... safe to read protected data ...
///
/// // Writer (main thread):
/// rcu.retire(ptr, free_fn);  // Defer deletion
/// rcu.tryAdvance();          // Call once per frame to advance epoch and free old items
/// ```
const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;
const Logger = @import("Logger.zig").Logger;

/// Maximum number of worker threads supported
pub const MAX_THREADS = 64;

/// Sentinel value indicating thread is not in a critical section
const INACTIVE: u64 = std.math.maxInt(u64);

/// Number of epoch slots in the retire ring buffer
/// We need 3 because: current epoch N, N-1 may have active readers, N-2 is safe to free
const EPOCH_SLOTS = 3;

/// A deferred free operation
const DeferredFree = struct {
    ptr: *anyopaque,
    free_fn: *const fn (*anyopaque) void,
};

/// Epoch-based RCU synchronization primitive
pub const Rcu = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Current global epoch (monotonically increasing)
    global_epoch: Atomic(u64),

    /// Per-thread epoch announcements
    /// INACTIVE means thread is not in a critical section
    thread_epochs: [MAX_THREADS]Atomic(u64),

    /// Ring buffer of items to free, indexed by epoch % EPOCH_SLOTS
    retire_lists: [EPOCH_SLOTS]std.ArrayListUnmanaged(DeferredFree),

    /// Mutex for retire list modifications (only touched by main thread, but ensures safety)
    retire_mutex: Io.Mutex,

    /// I/O subsystem (needed for mutex operations)
    io: Io,

    /// Number of registered threads
    thread_count: u32,

    /// Allocator for retire lists
    allocator: std.mem.Allocator,

    /// Statistics
    stats: Stats,

    pub const Stats = struct {
        epochs_advanced: u64 = 0,
        items_retired: u64 = 0,
        items_freed: u64 = 0,
        grace_period_waits: u64 = 0,
    };

    /// Initialize the RCU system
    pub fn init(allocator: std.mem.Allocator, thread_count: u32, io: Io) Self {
        var self = Self{
            .global_epoch = Atomic(u64).init(0),
            .thread_epochs = undefined,
            .retire_lists = undefined,
            .retire_mutex = Io.Mutex.init,
            .io = io,
            .thread_count = thread_count,
            .allocator = allocator,
            .stats = .{},
        };

        // Initialize all thread epochs to INACTIVE
        for (&self.thread_epochs) |*epoch| {
            epoch.* = Atomic(u64).init(INACTIVE);
        }

        // Initialize retire lists
        for (&self.retire_lists) |*list| {
            list.* = .{};
        }

        logger.info("RCU initialized with {} threads, {} epoch slots", .{ thread_count, EPOCH_SLOTS });

        return self;
    }

    /// Shutdown and free all pending items
    pub fn deinit(self: *Self) void {
        // Free all remaining items in retire lists
        var total_freed: usize = 0;
        for (&self.retire_lists) |*list| {
            for (list.items) |item| {
                item.free_fn(item.ptr);
                total_freed += 1;
            }
            list.deinit(self.allocator);
        }

        logger.info("RCU shutdown: freed {} remaining items", .{total_freed});
        logger.info("RCU stats: {} epochs, {} retired, {} freed, {} grace waits", .{
            self.stats.epochs_advanced,
            self.stats.items_retired,
            self.stats.items_freed,
            self.stats.grace_period_waits,
        });
    }

    /// Enter a read-side critical section
    /// Must be paired with readUnlock()
    /// Returns the current epoch for debugging purposes
    pub fn readLock(self: *Self, thread_id: u32) u64 {
        std.debug.assert(thread_id < self.thread_count);

        // Announce we're entering with current epoch
        // Acquire ordering ensures we see all writes from before this epoch
        const epoch = self.global_epoch.load(.acquire);
        self.thread_epochs[thread_id].store(epoch, .release);

        return epoch;
    }

    /// Exit a read-side critical section
    pub fn readUnlock(self: *Self, thread_id: u32) void {
        std.debug.assert(thread_id < self.thread_count);

        // Mark as inactive - no longer in critical section
        self.thread_epochs[thread_id].store(INACTIVE, .release);
    }

    /// Check if a thread is currently in a critical section
    pub fn isThreadActive(self: *const Self, thread_id: u32) bool {
        return self.thread_epochs[thread_id].load(.acquire) != INACTIVE;
    }

    /// Retire a pointer for deferred freeing
    /// The pointer will be freed once all current readers have exited their critical sections
    /// free_fn will be called with ptr when it's safe to free
    pub fn retire(self: *Self, ptr: *anyopaque, free_fn: *const fn (*anyopaque) void) void {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);

        const current_epoch = self.global_epoch.load(.acquire);
        const slot = current_epoch % EPOCH_SLOTS;

        self.retire_lists[slot].append(self.allocator, .{
            .ptr = ptr,
            .free_fn = free_fn,
        }) catch {
            // If we can't defer, we have to leak (better than crashing)
            logger.err("Failed to defer free - memory may leak", .{});
            return;
        };

        self.stats.items_retired += 1;
    }

    /// Retire with a typed free function for convenience
    pub fn retireTyped(self: *Self, comptime T: type, ptr: *T, free_fn: *const fn (*T) void) void {
        const erased_fn = struct {
            fn call(erased_ptr: *anyopaque) void {
                const typed_ptr: *T = @ptrCast(@alignCast(erased_ptr));
                free_fn(typed_ptr);
            }
        }.call;

        self.retire(@ptrCast(ptr), erased_fn);
    }

    /// Try to advance the epoch and free old items
    /// Call this once per frame from the main thread
    /// Returns true if epoch was advanced, false if readers are still in old epoch
    pub fn tryAdvance(self: *Self) bool {
        const current_epoch = self.global_epoch.load(.acquire);

        // Check if all threads have seen the current epoch (or are inactive)
        for (0..self.thread_count) |i| {
            const thread_epoch = self.thread_epochs[i].load(.acquire);
            if (thread_epoch != INACTIVE and thread_epoch < current_epoch) {
                // This thread is still in an old epoch, can't advance yet
                self.stats.grace_period_waits += 1;
                return false;
            }
        }

        // Safe to advance epoch
        const new_epoch = current_epoch + 1;
        self.global_epoch.store(new_epoch, .release);

        // Free items from 2 epochs ago (guaranteed all readers have passed)
        // Using modular arithmetic: slot to free = (new_epoch + 1) % EPOCH_SLOTS
        // When new_epoch = 2, we free slot 0 (epoch 0 items)
        // When new_epoch = 3, we free slot 1 (epoch 1 items)
        // etc.
        if (new_epoch >= 2) {
            const slot_to_free = (new_epoch - 2) % EPOCH_SLOTS;
            self.freeRetireList(slot_to_free);
        }

        self.stats.epochs_advanced += 1;
        return true;
    }

    /// Force synchronization - wait until all current readers have exited
    /// WARNING: This blocks! Use sparingly (e.g., during shutdown)
    pub fn synchronize(self: *Self) void {
        // Record the epoch we need to wait for
        const target_epoch = self.global_epoch.load(.acquire);

        // Spin until all threads have exited or advanced past target
        var spins: u32 = 0;
        while (true) {
            var all_clear = true;
            for (0..self.thread_count) |i| {
                const thread_epoch = self.thread_epochs[i].load(.acquire);
                if (thread_epoch != INACTIVE and thread_epoch <= target_epoch) {
                    all_clear = false;
                    break;
                }
            }

            if (all_clear) break;

            spins += 1;
            if (spins % 1000 == 0) {
                // Yield to other threads
                std.Thread.yield() catch {};
            }
            if (spins > 1_000_000) {
                logger.warn("RCU synchronize spinning for too long, possible deadlock", .{});
                spins = 0;
            }
        }

        // Now safe to advance
        _ = self.tryAdvance();
    }

    /// Free all items in a retire list slot
    fn freeRetireList(self: *Self, slot: u64) void {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);

        const list = &self.retire_lists[slot];
        const count = list.items.len;

        for (list.items) |item| {
            item.free_fn(item.ptr);
        }

        list.clearRetainingCapacity();
        self.stats.items_freed += count;
    }

    /// Get current epoch (for debugging)
    pub fn getCurrentEpoch(self: *const Self) u64 {
        return self.global_epoch.load(.acquire);
    }

    /// Get statistics
    pub fn getStats(self: *const Self) Stats {
        return self.stats;
    }

    /// Get number of items pending free across all retire lists
    pub fn getPendingFreeCount(self: *Self) usize {
        self.retire_mutex.lockUncancelable(self.io);
        defer self.retire_mutex.unlock(self.io);

        var count: usize = 0;
        for (self.retire_lists) |list| {
            count += list.items.len;
        }
        return count;
    }
};

/// RAII guard for read-side critical section
/// Automatically calls readUnlock when destroyed
pub const RcuReadGuard = struct {
    rcu: *Rcu,
    thread_id: u32,
    epoch: u64,

    pub fn init(rcu: *Rcu, thread_id: u32) RcuReadGuard {
        return .{
            .rcu = rcu,
            .thread_id = thread_id,
            .epoch = rcu.readLock(thread_id),
        };
    }

    pub fn deinit(self: *RcuReadGuard) void {
        self.rcu.readUnlock(self.thread_id);
    }
};

// Tests
test "Rcu basic operations" {
    const allocator = std.testing.allocator;
    var io_impl = Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    var rcu = Rcu.init(allocator, 4, io_impl.io());
    defer rcu.deinit();

    // Test read lock/unlock
    const epoch = rcu.readLock(0);
    try std.testing.expect(rcu.isThreadActive(0));
    try std.testing.expectEqual(@as(u64, 0), epoch);

    rcu.readUnlock(0);
    try std.testing.expect(!rcu.isThreadActive(0));

    // Test epoch advance
    try std.testing.expect(rcu.tryAdvance());
    try std.testing.expectEqual(@as(u64, 1), rcu.getCurrentEpoch());
}

test "Rcu deferred free" {
    const allocator = std.testing.allocator;
    var io_impl = Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    var rcu = Rcu.init(allocator, 2, io_impl.io());
    defer rcu.deinit();

    // Allocate something to free
    const ptr = try allocator.create(u64);
    ptr.* = 42;

    // Retire it
    rcu.retire(@ptrCast(ptr), struct {
        fn free(p: *anyopaque) void {
            const typed: *u64 = @ptrCast(@alignCast(p));
            std.testing.allocator.destroy(typed);
        }
    }.free);

    // Advance epochs until it's freed (need 2 advances)
    _ = rcu.tryAdvance(); // epoch 1
    _ = rcu.tryAdvance(); // epoch 2 - frees epoch 0 items

    try std.testing.expectEqual(@as(u64, 1), rcu.stats.items_freed);
}

test "Rcu grace period" {
    const allocator = std.testing.allocator;
    var io_impl = Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    var rcu = Rcu.init(allocator, 2, io_impl.io());
    defer rcu.deinit();

    // Thread 0 enters critical section at epoch 0
    _ = rcu.readLock(0);

    // Try to advance - should fail because thread 0 is in epoch 0
    // First advance to epoch 1 should succeed (no one was in epoch -1)
    try std.testing.expect(rcu.tryAdvance()); // epoch 0 -> 1

    // Now thread 0 is "behind" at epoch 0, can't advance further
    try std.testing.expect(!rcu.tryAdvance()); // blocked

    // Thread 0 exits
    rcu.readUnlock(0);

    // Now we can advance
    try std.testing.expect(rcu.tryAdvance()); // epoch 1 -> 2
}
