const std = @import("std");
const Entity = @import("../../Entity.zig").Entity;
const AbstractCow = @import("AbstractCow.zig").AbstractCow;
const CowVariant = @import("CowVariant.zig").CowVariant;
const CowVariants = @import("CowVariants.zig").CowVariants;

/// Cow - Standard cow entity with variant support
///
/// Modeled after Minecraft's Cow class which extends AbstractCow and adds:
/// - Variant data synchronization
/// - Save/load variant data
/// - Breeding offspring with variant inheritance
/// - Variant selection on spawn based on biome
pub const Cow = struct {
    const Self = @This();

    /// Base cow behavior (AI, sounds, interactions)
    base: AbstractCow,

    /// Current variant (determines texture and model)
    variant: *const CowVariant,

    /// Initialize a cow with the default variant
    pub fn init(entity: *Entity, allocator: std.mem.Allocator) Self {
        return .{
            .base = AbstractCow.init(entity, allocator),
            .variant = CowVariants.DEFAULT,
        };
    }

    /// Initialize a cow with a specific variant
    pub fn initWithVariant(entity: *Entity, allocator: std.mem.Allocator, variant: *const CowVariant) Self {
        return .{
            .base = AbstractCow.init(entity, allocator),
            .variant = variant,
        };
    }

    /// Register goals - delegates to AbstractCow
    pub fn registerGoals(self: *Self) void {
        self.base.registerGoals();
    }

    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }

    // ======================
    // Variant Management
    // ======================

    /// Get the current variant
    pub fn getVariant(self: *const Self) *const CowVariant {
        return self.variant;
    }

    /// Set the variant
    pub fn setVariant(self: *Self, variant: *const CowVariant) void {
        self.variant = variant;
    }

    /// Get the texture path for the current variant
    pub fn getTexture(self: *const Self) []const u8 {
        return self.variant.texture;
    }

    /// Get the model type for the current variant
    pub fn getModelType(self: *const Self) CowVariant.ModelType {
        return self.variant.model_type;
    }

    // ======================
    // Spawning
    // ======================

    /// Select variant based on spawn location/biome
    /// Called during finalizeSpawn in MC
    pub fn selectVariantForSpawn(self: *Self, temperature: CowVariant.Temperature) void {
        self.variant = CowVariants.selectVariantForSpawn(temperature);
    }

    // ======================
    // Breeding
    // ======================

    /// Get the variant for offspring
    /// Baby inherits variant from one parent randomly
    pub fn getOffspringVariant(self: *const Self, partner: *const Self, rand: *std.rand.Random) *const CowVariant {
        if (rand.boolean()) {
            return self.variant;
        } else {
            return partner.variant;
        }
    }

    // ======================
    // Convenience accessors to base
    // ======================

    /// Get the underlying entity
    pub fn getEntity(self: *Self) *Entity {
        return self.base.entity;
    }

    /// Get the goal selector
    pub fn getGoalSelector(self: *Self) *@import("../../ai/ai.zig").GoalSelector {
        return &self.base.goal_selector;
    }
};
