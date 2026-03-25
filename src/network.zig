pub const Socket = @import("network/Socket.zig");
pub const Address = Socket.Address;
pub const Connection = @import("network/Connection.zig").Connection;
pub const ConnectionManager = @import("network/ConnectionManager.zig").ConnectionManager;
pub const protocol = @import("network/protocol.zig");
pub const protocols = @import("network/protocols.zig");
pub const BinaryReader = protocol.BinaryReader;
pub const BinaryWriter = protocol.BinaryWriter;
