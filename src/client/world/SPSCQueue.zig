/// SPSCQueue - Lock-free Single-Producer Single-Consumer Queue
/// Uses atomic head/tail with a power-of-2 ring buffer for efficient modulo.
/// Perfect for upload thread (producer) -> main thread (consumer) communication.
const std = @import("std");

/// Lock-free SPSC queue for single producer, single consumer communication.
/// The producer owns the head (write position), consumer owns the tail (read position).
/// Uses one empty slot to distinguish full from empty state.
pub fn SPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Ring buffer storage
        buffer: []T,
        /// Capacity (always power of 2)
        capacity: usize,
        /// Mask for fast modulo (capacity - 1)
        mask: usize,

        /// Write position (owned by producer, read by consumer)
        head: std.atomic.Value(usize),
        /// Read position (owned by consumer, read by producer)
        tail: std.atomic.Value(usize),

        allocator: std.mem.Allocator,

        /// Initialize with given capacity (will be rounded up to power of 2)
        pub fn init(allocator: std.mem.Allocator, min_capacity: usize) !Self {
            // Round up to power of 2
            const capacity = std.math.ceilPowerOfTwo(usize, min_capacity) catch return error.CapacityTooLarge;

            const buffer = try allocator.alloc(T, capacity);

            return Self{
                .buffer = buffer,
                .capacity = capacity,
                .mask = capacity - 1,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Producer: try to push an item. Returns false if queue is full.
        /// Only safe to call from the producer thread.
        pub fn tryPush(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const next_head = (head + 1) & self.mask;

            // Check if full (next write position would hit read position)
            const tail = self.tail.load(.acquire);
            if (next_head == tail) {
                return false; // Queue full
            }

            // Write the item
            self.buffer[head] = item;

            // Publish the write (release ensures item is visible before head update)
            self.head.store(next_head, .release);

            return true;
        }

        /// Consumer: try to pop an item. Returns null if queue is empty.
        /// Only safe to call from the consumer thread.
        pub fn tryPop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);

            // Check if empty
            const head = self.head.load(.acquire);
            if (tail == head) {
                return null; // Queue empty
            }

            // Read the item (acquire ensures we see the producer's write)
            const item = self.buffer[tail];

            // Advance tail (release not strictly needed but good practice)
            const next_tail = (tail + 1) & self.mask;
            self.tail.store(next_tail, .release);

            return item;
        }

        /// Consumer: peek at the next item without removing it.
        /// Only safe to call from the consumer thread.
        pub fn peek(self: *Self) ?*const T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);

            if (tail == head) {
                return null; // Queue empty
            }

            return &self.buffer[tail];
        }

        /// Check if queue is empty (approximate, may change immediately)
        pub fn isEmpty(self: *const Self) bool {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);
            return tail == head;
        }

        /// Check if queue is full (approximate, may change immediately)
        pub fn isFull(self: *const Self) bool {
            const head = self.head.load(.acquire);
            const next_head = (head + 1) & self.mask;
            const tail = self.tail.load(.acquire);
            return next_head == tail;
        }

        /// Get approximate number of items in queue
        pub fn len(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return (head -% tail) & self.mask;
        }

        /// Get maximum capacity
        pub fn getCapacity(self: *const Self) usize {
            // Actual usable capacity is capacity - 1 (one slot always empty)
            return self.capacity - 1;
        }
    };
}

test "SPSCQueue basic operations" {
    const allocator = std.testing.allocator;

    var queue = try SPSCQueue(u32).init(allocator, 4);
    defer queue.deinit();

    // Initially empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());

    // Push items
    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));

    // Queue should be full (capacity 4 = 3 usable slots)
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.tryPush(4));

    // Pop items in FIFO order
    try std.testing.expectEqual(@as(?u32, 1), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 3), queue.tryPop());

    // Empty again
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());
}

test "SPSCQueue peek" {
    const allocator = std.testing.allocator;

    var queue = try SPSCQueue(u32).init(allocator, 8);
    defer queue.deinit();

    try std.testing.expect(queue.peek() == null);

    _ = queue.tryPush(42);

    const peeked = queue.peek();
    try std.testing.expect(peeked != null);
    try std.testing.expectEqual(@as(u32, 42), peeked.?.*);

    // Peek doesn't remove
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    // Pop removes
    try std.testing.expectEqual(@as(?u32, 42), queue.tryPop());
    try std.testing.expect(queue.isEmpty());
}

test "SPSCQueue wraparound" {
    const allocator = std.testing.allocator;

    var queue = try SPSCQueue(u32).init(allocator, 4);
    defer queue.deinit();

    // Fill and drain multiple times to test wraparound
    for (0..10) |round| {
        const base: u32 = @intCast(round * 3);

        try std.testing.expect(queue.tryPush(base + 1));
        try std.testing.expect(queue.tryPush(base + 2));
        try std.testing.expect(queue.tryPush(base + 3));

        try std.testing.expectEqual(@as(?u32, base + 1), queue.tryPop());
        try std.testing.expectEqual(@as(?u32, base + 2), queue.tryPop());
        try std.testing.expectEqual(@as(?u32, base + 3), queue.tryPop());
    }
}
