const std = @import("std");
const Entity = @import("../../Entity.zig").Entity;
const LivingEntity = @import("../../LivingEntity.zig").LivingEntity;
const Mob = @import("../../Mob.zig").Mob;
const PathfinderMob = @import("../../PathfinderMob.zig").PathfinderMob;
const AgeableMob = @import("../../AgeableMob.zig").AgeableMob;
const Animal = @import("../Animal.zig").Animal;
const AbstractCow = @import("AbstractCow.zig").AbstractCow;

/// MushroomCow (Mooshroom) - Special cow variant that spawns in mushroom biomes
///
/// Modeled after Minecraft's MushroomCow class which extends AbstractCow and adds:
/// - Red/Brown variants (changes with lightning strike)
/// - Shearing to convert to regular Cow (drops mushrooms)
/// - Mushroom stew milking (bowl instead of bucket)
/// - Suspicious stew effects when fed flowers (brown variant only)
/// - Spawns only on mycelium in mushroom biomes
///
/// Inheritance: Entity -> LivingEntity -> Mob -> PathfinderMob -> AgeableMob -> Animal -> AbstractCow -> MushroomCow
pub const MushroomCow = struct {
    const Self = @This();

    /// Base cow behavior (AI, sounds, interactions)
    base: AbstractCow,

    /// Current variant (red or brown)
    variant: Variant,

    /// Suspicious stew effects (for brown mooshroom fed flowers)
    /// TODO: Implement when potion effects are added
    stew_effects: ?StewEffects,

    /// UUID of last lightning bolt that hit this mooshroom
    /// Used to prevent multiple conversions from same bolt
    last_lightning_uuid: ?u128,

    /// Mooshroom variants
    pub const Variant = enum(u8) {
        red = 0,
        brown = 1,

        pub const DEFAULT = Variant.red;

        pub fn toString(self: Variant) []const u8 {
            return switch (self) {
                .red => "red",
                .brown => "brown",
            };
        }

        /// Get the opposite variant (for lightning conversion)
        pub fn opposite(self: Variant) Variant {
            return switch (self) {
                .red => .brown,
                .brown => .red,
            };
        }

        /// Get the mushroom block type for this variant
        pub fn getMushroomBlockId(self: Variant) u16 {
            return switch (self) {
                .red => 0, // TODO: RED_MUSHROOM block ID
                .brown => 0, // TODO: BROWN_MUSHROOM block ID
            };
        }
    };

    /// Placeholder for suspicious stew effects
    pub const StewEffects = struct {
        // TODO: Implement when potion effects are added
        effect_id: u8,
        duration: i32,
    };

    /// Initialize a mooshroom with default (red) variant
    pub fn init(entity: *Entity, allocator: std.mem.Allocator) Self {
        return .{
            .base = AbstractCow.init(entity, allocator),
            .variant = Variant.DEFAULT,
            .stew_effects = null,
            .last_lightning_uuid = null,
        };
    }

    /// Initialize a mooshroom with a specific variant
    pub fn initWithVariant(entity: *Entity, allocator: std.mem.Allocator, variant: Variant) Self {
        return .{
            .base = AbstractCow.init(entity, allocator),
            .variant = variant,
            .stew_effects = null,
            .last_lightning_uuid = null,
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
    pub fn getVariant(self: *const Self) Variant {
        return self.variant;
    }

    /// Set the variant
    pub fn setVariant(self: *Self, variant: Variant) void {
        self.variant = variant;
    }

    /// Get the texture path for the current variant
    pub fn getTexture(self: *const Self) []const u8 {
        return switch (self.variant) {
            .red => "entity/cow/red_mooshroom",
            .brown => "entity/cow/brown_mooshroom",
        };
    }

    // ======================
    // Lightning Conversion
    // ======================

    /// Handle being struck by lightning
    /// Converts between red and brown variants
    pub fn onLightningStrike(self: *Self, lightning_uuid: u128) void {
        // Prevent multiple conversions from same lightning bolt
        if (self.last_lightning_uuid) |last_uuid| {
            if (last_uuid == lightning_uuid) {
                return;
            }
        }

        // Convert to opposite variant
        self.variant = self.variant.opposite();
        self.last_lightning_uuid = lightning_uuid;

        // TODO: Play conversion sound (SoundEvents.MOOSHROOM_CONVERT)
    }

    // ======================
    // Shearing
    // ======================

    /// Check if this mooshroom can be sheared
    pub fn readyForShearing(self: *const Self) bool {
        // Can shear if alive and not a baby
        // TODO: Check isBaby when age system is implemented
        _ = self;
        return true;
    }

    /// Shear this mooshroom, converting it to a regular cow
    /// Returns the number of mushrooms to drop (typically 5)
    pub fn shear(self: *Self) u8 {
        if (!self.readyForShearing()) {
            return 0;
        }

        // TODO: Actually convert to Cow entity
        // TODO: Spawn mushroom items based on variant
        // TODO: Play shear sound (SoundEvents.MOOSHROOM_SHEAR)
        // TODO: Spawn explosion particle

        _ = self;
        return 5; // Number of mushrooms dropped
    }

    // ======================
    // Stew Interaction
    // ======================

    /// Try to milk stew from this mooshroom (using a bowl)
    /// Returns true if successful
    pub fn tryMilkStew(self: *Self) bool {
        // TODO: Implement when inventory system is added
        // - Check if player has bowl
        // - Check if not baby
        // - If brown and has stew_effects, give suspicious stew
        // - Otherwise give mushroom stew
        // - Play appropriate sound
        _ = self;
        return false;
    }

    /// Feed a flower to this mooshroom (brown variant only)
    /// Gives the mooshroom suspicious stew effects
    pub fn feedFlower(self: *Self, flower_item_id: u16) bool {
        // Only brown mooshrooms can be fed flowers
        if (self.variant != .brown) {
            return false;
        }

        // TODO: Look up flower's suspicious stew effects
        // TODO: Set stew_effects
        // TODO: Play eat sound (SoundEvents.MOOSHROOM_EAT)
        _ = flower_item_id;
        return false;
    }

    // ======================
    // Spawning
    // ======================

    /// Check if position is valid for mooshroom spawn
    /// Must be on mycelium in mushroom biome
    pub fn isValidSpawnPosition(block_below_id: u16, light_level: u8) bool {
        // TODO: Check for MYCELIUM block
        // TODO: Check biome is mushroom fields
        _ = block_below_id;
        _ = light_level;
        return false;
    }

    // ======================
    // Breeding
    // ======================

    /// Get the variant for offspring
    /// Small chance (1/1024) to mutate to opposite color if parents match
    pub fn getOffspringVariant(self: *const Self, partner: *const Self, rand: *std.rand.Random) Variant {
        const self_variant = self.variant;
        const partner_variant = partner.variant;

        // If parents are same variant, small chance to mutate
        if (self_variant == partner_variant) {
            if (rand.intRangeAtMost(u32, 0, 1023) == 0) {
                return self_variant.opposite();
            }
        }

        // Otherwise random parent's variant
        if (rand.boolean()) {
            return self_variant;
        } else {
            return partner_variant;
        }
    }

    // ======================
    // Hierarchy Accessors
    // ======================

    /// Get the AbstractCow wrapper
    pub fn getAbstractCow(self: *Self) *AbstractCow {
        return &self.base;
    }

    /// Get the Animal wrapper
    pub fn getAnimal(self: *Self) *Animal {
        return self.base.getAnimal();
    }

    /// Get the AgeableMob wrapper
    pub fn getAgeable(self: *Self) *AgeableMob {
        return self.base.getAgeable();
    }

    /// Get the PathfinderMob wrapper
    pub fn getPathfinder(self: *Self) *PathfinderMob {
        return self.base.getPathfinder();
    }

    /// Get the Mob wrapper
    pub fn getMob(self: *Self) *Mob {
        return self.base.getMob();
    }

    /// Get the LivingEntity wrapper
    pub fn getLiving(self: *Self) *LivingEntity {
        return self.base.getLiving();
    }

    /// Get the underlying entity
    pub fn getEntity(self: *Self) *Entity {
        return self.base.getEntity();
    }

    // ======================
    // Convenience accessors
    // ======================

    /// Get the goal selector
    pub fn getGoalSelector(self: *Self) *@import("../../ai/ai.zig").GoalSelector {
        return &self.base.goal_selector;
    }

    /// Check if this is a baby
    pub fn isBaby(self: *const Self) bool {
        return self.base.isBaby();
    }

    /// Get scale for rendering
    pub fn getScale(self: *const Self) f32 {
        return self.base.getScale();
    }

    /// Attempt to jump
    pub fn jump(self: *Self) void {
        self.base.jump();
    }

    /// Try to jump over an obstacle
    pub fn tryJumpOver(self: *Self, obstacle_height: f32) bool {
        return self.base.tryJumpOver(obstacle_height);
    }
};
