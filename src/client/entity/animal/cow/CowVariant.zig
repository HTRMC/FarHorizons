const std = @import("std");

/// CowVariant - Defines a cow variant with model type and texture
///
/// Modeled after Minecraft's CowVariant record which contains:
/// - ModelAndTexture (model type + texture path)
/// - SpawnPrioritySelectors (biome-based spawn conditions)
///
/// Variants determine the visual appearance of cows based on
/// the biome they spawn in (temperate, warm, cold).
pub const CowVariant = struct {
    const Self = @This();

    /// The model type determines which model to use for rendering
    model_type: ModelType,

    /// Texture identifier (e.g., "entity/cow/temperate_cow")
    texture: []const u8,

    /// Spawn priority (higher = more likely in matching biomes)
    spawn_priority: i32,

    /// Create a new cow variant
    pub fn init(model_type: ModelType, texture: []const u8, spawn_priority: i32) Self {
        return .{
            .model_type = model_type,
            .texture = texture,
            .spawn_priority = spawn_priority,
        };
    }

    /// Model types for cow variants
    /// Each type may have slightly different geometry
    pub const ModelType = enum(u8) {
        /// Normal/temperate cow model
        normal = 0,
        /// Cold biome cow model (thicker fur)
        cold = 1,
        /// Warm biome cow model (shorter fur)
        warm = 2,

        pub fn toString(self: ModelType) []const u8 {
            return switch (self) {
                .normal => "normal",
                .cold => "cold",
                .warm => "warm",
            };
        }
    };

    /// Temperature category for biome-based variant selection
    pub const Temperature = enum(u8) {
        temperate = 0,
        warm = 1,
        cold = 2,

        /// Get the appropriate model type for this temperature
        pub fn getModelType(self: Temperature) ModelType {
            return switch (self) {
                .temperate => .normal,
                .warm => .warm,
                .cold => .cold,
            };
        }
    };

    /// Check if this variant should spawn in the given biome temperature
    pub fn shouldSpawnIn(self: *const Self, temperature: Temperature) bool {
        return self.model_type == temperature.getModelType();
    }
};
