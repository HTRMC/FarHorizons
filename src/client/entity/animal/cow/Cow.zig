const std = @import("std");
const Entity = @import("../../Entity.zig").Entity;
const ai = @import("../../ai/ai.zig");
const GoalSelector = ai.GoalSelector;
const LookControl = ai.LookControl;
const RandomStrollGoal = ai.RandomStrollGoal;
const LookAtPlayerGoal = ai.LookAtPlayerGoal;
const RandomLookAroundGoal = ai.RandomLookAroundGoal;

/// Cow-specific AI and behavior
/// Modeled after Minecraft's AbstractCow.registerGoals()
pub const Cow = struct {
    const Self = @This();

    // AI components (owned by Cow, referenced by Entity)
    goal_selector: GoalSelector,
    look_control: LookControl,

    // Goals (stored here, pointers passed to goal selector)
    stroll_goal: RandomStrollGoal,
    look_at_player_goal: LookAtPlayerGoal,
    random_look_goal: RandomLookAroundGoal,

    // Reference to the entity
    entity: *Entity,

    /// Initialize cow AI for an entity
    /// This is similar to MC's AbstractCow.registerGoals()
    pub fn init(entity: *Entity, allocator: std.mem.Allocator) Self {
        var cow = Self{
            .entity = entity,
            .goal_selector = GoalSelector.init(allocator),
            .look_control = LookControl.init(entity),
            .stroll_goal = undefined,
            .look_at_player_goal = undefined,
            .random_look_goal = undefined,
        };

        // Initialize goals with references to cow's look_control
        cow.stroll_goal = RandomStrollGoal.init(entity, 0.1, 120);
        cow.look_at_player_goal = LookAtPlayerGoal.init(entity, &cow.look_control, 6.0, 0.02);
        cow.random_look_goal = RandomLookAroundGoal.init(entity, &cow.look_control);

        return cow;
    }

    /// Register all goals with the goal selector
    /// Call this after init() once the Cow struct is at its final memory location
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
    pub fn registerGoals(self: *Self) void {
        // Priority 5: Random strolling (wandering)
        self.goal_selector.addGoal(5, self.stroll_goal.asGoal());

        // Priority 6: Look at nearby players
        self.goal_selector.addGoal(6, self.look_at_player_goal.asGoal());

        // Priority 7: Random looking around when idle
        self.goal_selector.addGoal(7, self.random_look_goal.asGoal());

        // Link AI components to entity
        self.entity.goal_selector = &self.goal_selector;
        self.entity.look_control = &self.look_control;
    }

    pub fn deinit(self: *Self) void {
        self.goal_selector.deinit();
        // Unlink from entity
        self.entity.goal_selector = null;
        self.entity.look_control = null;
    }
};
