/// CowData component - cow-specific data
/// Extracted from Cow.zig
pub const CowData = struct {
    /// Cow variant
    variant: Variant = .temperate,

    /// Variant enum matching CowVariants
    pub const Variant = enum(u8) {
        temperate = 0,
        warm = 1,
        cold = 2,
    };

    /// Temperature for variant selection
    pub const Temperature = enum {
        warm,
        temperate,
        cold,
    };

    pub fn init() CowData {
        return .{};
    }

    pub fn initWithVariant(variant: Variant) CowData {
        return .{
            .variant = variant,
        };
    }

    /// Select variant based on spawn temperature
    pub fn selectVariantForSpawn(temperature: Temperature) Variant {
        return switch (temperature) {
            .warm => .warm,
            .temperate => .temperate,
            .cold => .cold,
        };
    }

    /// Get texture path for variant
    pub fn getTexturePath(self: *const CowData) []const u8 {
        return switch (self.variant) {
            .temperate => "textures/entity/cow/temperate_cow.png",
            .warm => "textures/entity/cow/warm_cow.png",
            .cold => "textures/entity/cow/cold_cow.png",
        };
    }

    /// Check if this variant uses the cold/fluffy model
    pub fn usesColdModel(self: *const CowData) bool {
        return self.variant == .cold;
    }
};
