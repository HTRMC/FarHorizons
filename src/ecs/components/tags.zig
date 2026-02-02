/// Tags component - boolean flags for entity categorization
/// Used for fast filtering in queries
pub const Tags = packed struct {
    /// Is this a living entity (has health)
    is_living: bool = false,

    /// Is this a mob (has AI)
    is_mob: bool = false,

    /// Is this an animal (can breed)
    is_animal: bool = false,

    /// Is this a cow
    is_cow: bool = false,

    /// Is this a mooshroom
    is_mooshroom: bool = false,

    /// Is this a player (server-authoritative player entity)
    is_player: bool = false,

    /// Is this the local player (client-controlled player entity)
    is_local_player: bool = false,

    /// Is this entity marked for removal
    marked_for_removal: bool = false,

    pub fn init() Tags {
        return .{};
    }

    /// Create tags for a cow entity
    pub fn cow() Tags {
        return .{
            .is_living = true,
            .is_mob = true,
            .is_animal = true,
            .is_cow = true,
        };
    }

    /// Create tags for a mooshroom entity
    pub fn mooshroom() Tags {
        return .{
            .is_living = true,
            .is_mob = true,
            .is_animal = true,
            .is_mooshroom = true,
        };
    }

    /// Create tags for a player entity (server-side)
    pub fn player() Tags {
        return .{
            .is_living = true,
            .is_player = true,
        };
    }

    /// Create tags for a local player entity (client-side with control)
    pub fn localPlayer() Tags {
        return .{
            .is_living = true,
            .is_player = true,
            .is_local_player = true,
        };
    }
};
