/// RenderData component - data needed for rendering
/// Extracted from Entity.zig and Cow.zig
pub const RenderData = struct {
    /// Entity type for texture/model selection
    entity_type: EntityType,

    /// Texture index (variant-specific)
    texture_index: u8 = 0,

    /// Model type (for variants with different models)
    model_type: ModelType = .normal,

    /// Whether this is a baby (affects model selection)
    is_baby: bool = false,

    /// Entity type enum
    pub const EntityType = enum(u8) {
        cow = 0,
        pig = 1,
        sheep = 2,
        player = 3,
        mooshroom = 4,
    };

    /// Model type for variants
    pub const ModelType = enum(u8) {
        normal = 0,
        cold = 1, // Cold cow variant with fluffy texture
    };

    pub fn init(entity_type: EntityType) RenderData {
        return .{
            .entity_type = entity_type,
        };
    }

    pub fn cow() RenderData {
        return .{
            .entity_type = .cow,
        };
    }

    pub fn babyCow() RenderData {
        return .{
            .entity_type = .cow,
            .is_baby = true,
        };
    }

    pub fn mooshroom() RenderData {
        return .{
            .entity_type = .mooshroom,
        };
    }
};
