const std = @import("std");
const Entity = @import("../../Entity.zig").Entity;
const Animal = @import("../Animal.zig").Animal;
const ai = @import("../../ai/ai.zig");
const GoalSelector = ai.GoalSelector;
const LookControl = ai.LookControl;
const RandomStrollGoal = ai.RandomStrollGoal;
const LookAtPlayerGoal = ai.LookAtPlayerGoal;
const RandomLookAroundGoal = ai.RandomLookAroundGoal;

/// AbstractCow - Base cow behavior shared by Cow and MushroomCow
///
/// Modeled after Minecraft's AbstractCow class which extends Animal and contains:
/// - Common AI goals (stroll, look at player, look around)
/// - Sound definitions
/// - Milking interaction
/// - Attribute definitions
///
/// Inheritance chain: Entity -> AgeableMob -> Animal -> AbstractCow -> Cow/MushroomCow
///
/// MC's AbstractCow.registerGoals() priorities:
/// 0 - FloatGoal (swim)           - NOT IMPLEMENTED
/// 1 - PanicGoal (flee)           - NOT IMPLEMENTED
/// 2 - BreedGoal                  - NOT IMPLEMENTED
/// 3 - TemptGoal (follow food)    - NOT IMPLEMENTED
/// 4 - FollowParentGoal           - NOT IMPLEMENTED
/// 5 - WaterAvoidingRandomStrollGoal -> RandomStrollGoal
/// 6 - LookAtPlayerGoal
/// 7 - RandomLookAroundGoal
pub const AbstractCow = struct {
    const Self = @This();

    /// Base animal behavior (age, breeding)
    animal: Animal,

    // AI components (owned by AbstractCow, referenced by Entity)
    goal_selector: GoalSelector,
    look_control: LookControl,

    // Goals (stored here, pointers passed to goal selector)
    stroll_goal: RandomStrollGoal,
    look_at_player_goal: LookAtPlayerGoal,
    random_look_goal: RandomLookAroundGoal,

    // Attributes
    pub const MAX_HEALTH: f32 = 10.0;
    pub const MOVEMENT_SPEED: f32 = 0.2;

    // Dimensions
    pub const ADULT_WIDTH: f32 = 0.9;
    pub const ADULT_HEIGHT: f32 = 1.4;
    pub const BABY_WIDTH: f32 = ADULT_WIDTH * 0.5;
    pub const BABY_HEIGHT: f32 = ADULT_HEIGHT * 0.5;

    // Sound volume
    pub const SOUND_VOLUME: f32 = 0.4;

    /// Initialize cow AI for an entity (adult)
    pub fn init(entity: *Entity, allocator: std.mem.Allocator) Self {
        var cow = Self{
            .animal = Animal.init(entity),
            .goal_selector = GoalSelector.init(allocator),
            .look_control = LookControl.init(entity),
            .stroll_goal = undefined,
            .look_at_player_goal = undefined,
            .random_look_goal = undefined,
        };

        // Set cow dimensions
        entity.width = ADULT_WIDTH;
        entity.height = ADULT_HEIGHT;

        // Initialize goals with references to cow's look_control
        cow.stroll_goal = RandomStrollGoal.init(entity, 0.1, 120);
        cow.look_at_player_goal = LookAtPlayerGoal.init(entity, &cow.look_control, 6.0, 0.02);
        cow.random_look_goal = RandomLookAroundGoal.init(entity, &cow.look_control);

        return cow;
    }

    /// Initialize cow AI for a baby entity
    pub fn initBaby(entity: *Entity, allocator: std.mem.Allocator) Self {
        var cow = Self{
            .animal = Animal.initBaby(entity),
            .goal_selector = GoalSelector.init(allocator),
            .look_control = LookControl.init(entity),
            .stroll_goal = undefined,
            .look_at_player_goal = undefined,
            .random_look_goal = undefined,
        };

        // Set baby cow dimensions
        entity.width = BABY_WIDTH;
        entity.height = BABY_HEIGHT;

        // Initialize goals with references to cow's look_control
        cow.stroll_goal = RandomStrollGoal.init(entity, 0.1, 120);
        cow.look_at_player_goal = LookAtPlayerGoal.init(entity, &cow.look_control, 6.0, 0.02);
        cow.random_look_goal = RandomLookAroundGoal.init(entity, &cow.look_control);

        return cow;
    }

    /// Register all goals with the goal selector
    /// Call this after init() once the struct is at its final memory location
    pub fn registerGoals(self: *Self) void {
        // Priority 5: Random strolling (wandering)
        self.goal_selector.addGoal(5, self.stroll_goal.asGoal());

        // Priority 6: Look at nearby players
        self.goal_selector.addGoal(6, self.look_at_player_goal.asGoal());

        // Priority 7: Random looking around when idle
        self.goal_selector.addGoal(7, self.random_look_goal.asGoal());

        // Link AI components to entity
        self.animal.ageable.entity.goal_selector = &self.goal_selector;
        self.animal.ageable.entity.look_control = &self.look_control;
    }

    pub fn deinit(self: *Self) void {
        self.goal_selector.deinit();
        // Unlink from entity
        self.animal.ageable.entity.goal_selector = null;
        self.animal.ageable.entity.look_control = null;
    }

    // ======================
    // Convenience accessors
    // ======================

    /// Get the underlying entity
    pub fn getEntity(self: *Self) *Entity {
        return self.animal.getEntity();
    }

    /// Check if this is a baby
    pub fn isBaby(self: *const Self) bool {
        return self.animal.isBaby();
    }

    /// Set baby state
    pub fn setBaby(self: *Self, baby: bool) void {
        self.animal.setBaby(baby);
        // Update dimensions
        if (baby) {
            self.animal.ageable.entity.width = BABY_WIDTH;
            self.animal.ageable.entity.height = BABY_HEIGHT;
        } else {
            self.animal.ageable.entity.width = ADULT_WIDTH;
            self.animal.ageable.entity.height = ADULT_HEIGHT;
        }
    }

    /// Get scale for rendering
    pub fn getScale(self: *const Self) f32 {
        return self.animal.getScale();
    }

    /// Tick the cow (age, love mode, etc.)
    pub fn tick(self: *Self) void {
        self.animal.tick();
    }

    // ======================
    // Food
    // ======================

    /// Check if the given item is food for cows
    /// Cows eat wheat (COW_FOOD tag in MC)
    pub fn isFood(_: *const Self, item_id: u16) bool {
        // TODO: Use proper item tags when implemented
        // For now, hardcode wheat ID (would be from Items registry)
        const WHEAT_ID: u16 = 0; // Placeholder
        return item_id == WHEAT_ID;
    }

    // ======================
    // Sounds
    // ======================

    pub const Sound = enum {
        ambient,
        hurt,
        death,
        step,
        milk,
    };

    /// Get the ambient sound for this cow type
    /// Override in subclasses for different sounds (e.g., MushroomCow)
    pub fn getAmbientSound(_: *const Self) Sound {
        return .ambient;
    }

    /// Get the hurt sound
    pub fn getHurtSound(_: *const Self) Sound {
        return .hurt;
    }

    /// Get the death sound
    pub fn getDeathSound(_: *const Self) Sound {
        return .death;
    }

    /// Get sound volume (0.4 for cows)
    pub fn getSoundVolume(_: *const Self) f32 {
        return SOUND_VOLUME;
    }

    // ======================
    // Interactions
    // ======================

    /// Handle milking interaction
    /// Returns true if milking was successful
    pub fn tryMilk(self: *Self) bool {
        // Can't milk babies
        if (self.isBaby()) {
            return false;
        }

        // TODO: Implement when inventory/items are added
        // - Check if player has bucket
        // - Give milk bucket
        // - Play milk sound
        return false;
    }
};
