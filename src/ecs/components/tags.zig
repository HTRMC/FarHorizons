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

    /// Is this a player
    is_player: bool = false,

    /// Is this entity marked for removal
    marked_for_removal: bool = false,

    /// Padding to make it a full byte
    _padding: u1 = 0,

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

    /// Create tags for a player entity
    pub fn player() Tags {
        return .{
            .is_living = true,
            .is_player = true,
        };
    }
};
