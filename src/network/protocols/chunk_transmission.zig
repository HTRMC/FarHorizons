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
pub var client_game_state: ?*@import("../../GameState.zig") = null;

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
pub fn clientReceive(_: *Connection, reader: *BinaryReader) anyerror!void {
    const cx = try reader.readInt(i32);
    const cy = try reader.readInt(i32);
    const cz = try reader.readInt(i32);
    const data = try reader.readLenPrefixedSlice();
    const key = WorldState.ChunkKey{ .cx = cx, .cy = cy, .cz = cz };

    const state = client_game_state orelse return;

    // Skip if already loaded
    if (state.chunk_map.get(key) != null) return;

    // Acquire chunk from pool and decode
    const chunk = state.chunk_pool.acquire();
    chunk_codec.decodeToPalette(data, &chunk.blocks) catch |err| {
        std.log.warn("Failed to decode chunk ({},{},{}): {s}", .{ cx, cy, cz, @errorName(err) });
        state.chunk_pool.release(chunk);
        return;
    };

    // Insert into chunk map
    state.chunk_map.put(key, chunk);

    // Allocate light map
    const lm = state.light_map_pool.acquire();
    state.light_maps.put(key, lm) catch {
        state.light_map_pool.release(lm);
    };

    // Update surface heights
    state.surface_height_map.updateFromChunk(key, chunk);

    std.log.debug("Received chunk ({},{},{})", .{ cx, cy, cz });
}

pub fn register() void {
    protocol.registerClientHandler(id, clientReceive);
}
