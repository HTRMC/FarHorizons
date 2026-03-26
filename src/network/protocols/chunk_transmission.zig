const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const WorldState = @import("../../world/WorldState.zig");
const chunk_codec = @import("../../world/storage/chunk_codec.zig");

pub const id: u8 = protocol.CHUNK_TRANSMISSION;

/// Pointer to client-side game state for inserting received chunks.
/// Set by the client on connect, null when disconnected.
pub var client_game_state: ?*@import("../../world/GameState.zig") = null;

/// Server → Client: send a chunk's block data (encoded with chunk_codec).
pub fn sendChunk(
    conn: *Connection,
    socket: anytype,
    key: WorldState.ChunkKey,
    encoded_data: []const u8,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(i32, key.cx);
    writer.writeInt(i32, key.cy);
    writer.writeInt(i32, key.cz);
    writer.writeLenPrefixedSlice(encoded_data);
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Client receives chunk data from server.
/// Decodes the chunk and queues it for main-thread integration (thread-safe).
pub fn clientReceive(_: *Connection, reader: *BinaryReader) anyerror!void {
    const cx = try reader.readInt(i32);
    const cy = try reader.readInt(i32);
    const cz = try reader.readInt(i32);
    const data = try reader.readLenPrefixedSlice();
    const key = WorldState.ChunkKey{ .cx = cx, .cy = cy, .cz = cz };

    const state = client_game_state orelse return;

    // Acquire chunk from pool (thread-safe) and decode
    const chunk = state.chunk_pool.acquire();
    chunk_codec.decodeToPalette(data, &chunk.blocks) catch |err| {
        std.log.warn("Failed to decode chunk ({},{},{}): {s}", .{ cx, cy, cz, @errorName(err) });
        state.chunk_pool.release(chunk);
        return;
    };

    // Queue for main-thread integration (thread-safe ring buffer)
    state.queueNetworkChunk(key, chunk);
}

pub fn register() void {
    protocol.registerClientHandler(id, clientReceive);
}
