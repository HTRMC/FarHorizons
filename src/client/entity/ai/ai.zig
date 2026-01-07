// AI Module - Goal-based AI system for entities
//
// Architecture matches Minecraft:
// - GoalSelector manages prioritized goals
// - LookControl handles smooth head rotation
// - Goals set look targets, LookControl does the rotation

pub const Goal = @import("Goal.zig").Goal;
pub const GoalSelector = @import("Goal.zig").GoalSelector;
pub const Flag = @import("Goal.zig").Flag;
pub const FlagSet = @import("Goal.zig").FlagSet;
pub const WrappedGoal = @import("Goal.zig").WrappedGoal;

// Controllers
pub const LookControl = @import("LookControl.zig").LookControl;

// Goals
pub const RandomStrollGoal = @import("RandomStrollGoal.zig").RandomStrollGoal;
pub const LookAtPlayerGoal = @import("LookAtPlayerGoal.zig").LookAtPlayerGoal;
pub const RandomLookAroundGoal = @import("RandomLookAroundGoal.zig").RandomLookAroundGoal;
