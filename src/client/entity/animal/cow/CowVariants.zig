const CowVariant = @import("CowVariant.zig").CowVariant;
const ModelType = CowVariant.ModelType;
const Temperature = CowVariant.Temperature;

/// CowVariants - Registry of all cow variants
///
/// Modeled after Minecraft's CowVariants class which contains:
/// - Static variant definitions (TEMPERATE, WARM, COLD)
/// - Bootstrap method for data-driven registration
///
/// In MC, variants are registered to Registries.COW_VARIANT
/// and selected based on biome at spawn time.
pub const CowVariants = struct {
    /// Temperate cow - default variant for most biomes
    /// Normal model, standard brown texture
    pub const TEMPERATE = CowVariant.init(
        .normal,
        "entity/cow/temperate_cow",
        0, // Fallback priority
    );

    /// Warm cow - spawns in warm biomes (savanna, desert, jungle)
    /// Warm model with shorter fur texture
    pub const WARM = CowVariant.init(
        .warm,
        "entity/cow/warm_cow",
        1,
    );

    /// Cold cow - spawns in cold biomes (taiga, snowy plains)
    /// Cold model with thicker fur texture
    pub const COLD = CowVariant.init(
        .cold,
        "entity/cow/cold_cow",
        1,
    );

    /// Default variant (temperate)
    pub const DEFAULT = &TEMPERATE;

    /// All registered variants
    pub const ALL = [_]*const CowVariant{
        &TEMPERATE,
        &WARM,
        &COLD,
    };

    /// Get variant by model type
    pub fn getByModelType(model_type: ModelType) *const CowVariant {
        return switch (model_type) {
            .normal => &TEMPERATE,
            .warm => &WARM,
            .cold => &COLD,
        };
    }

    /// Get variant for a given temperature/biome type
    pub fn getForTemperature(temperature: Temperature) *const CowVariant {
        return switch (temperature) {
            .temperate => &TEMPERATE,
            .warm => &WARM,
            .cold => &COLD,
        };
    }

    /// Select a variant to spawn based on biome temperature
    /// Returns the appropriate variant or default if no match
    pub fn selectVariantForSpawn(temperature: Temperature) *const CowVariant {
        return getForTemperature(temperature);
    }

    /// Get a random variant (for testing/debug)
    pub fn getRandom(rand: *std.rand.Random) *const CowVariant {
        const index = rand.intRangeAtMost(usize, 0, ALL.len - 1);
        return ALL[index];
    }
};

const std = @import("std");
