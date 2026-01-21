/// Age component - for entities that can be babies and grow up
/// Extracted from AgeableMob.zig
pub const Age = struct {
    /// Current age (negative = baby, 0+ = adult)
    /// Baby ages increment toward 0, adult breeding cooldown decrements toward 0
    age: i32 = DEFAULT_AGE,

    /// Forced age accumulator (from feeding)
    forced_age: i32 = 0,

    /// Timer for forced age particles
    forced_age_timer: i32 = 0,

    // Constants from AgeableMob
    pub const BABY_START_AGE: i32 = -24000; // 20 minutes to grow up
    pub const DEFAULT_AGE: i32 = 0;
    pub const BABY_SCALE: f32 = 0.5;
    pub const FORCED_AGE_PARTICLE_TICKS: i32 = 40;

    pub fn init() Age {
        return .{};
    }

    pub fn initBaby() Age {
        return .{
            .age = BABY_START_AGE,
        };
    }

    /// Check if this is a baby
    pub fn isBaby(self: *const Age) bool {
        return self.age < 0;
    }

    /// Check if can breed (adult with no cooldown)
    pub fn canBreed(self: *const Age) bool {
        return self.age == 0;
    }

    /// Get scale for rendering
    pub fn getScale(self: *const Age) f32 {
        return if (self.isBaby()) BABY_SCALE else 1.0;
    }

    /// Set baby state
    pub fn setBaby(self: *Age, baby: bool) void {
        self.age = if (baby) BABY_START_AGE else 0;
    }

    /// Age up by a number of seconds
    pub fn ageUp(self: *Age, seconds: i32, forced: bool) void {
        var new_age = self.age;
        new_age += seconds * 20; // Convert seconds to ticks

        // Clamp to 0 if crossing boundary
        if (new_age > 0 and self.age < 0) {
            new_age = 0;
        }

        const delta = new_age - self.age;
        self.age = new_age;

        if (forced) {
            self.forced_age += delta;
            if (self.forced_age_timer == 0) {
                self.forced_age_timer = FORCED_AGE_PARTICLE_TICKS;
            }
        }

        // Apply remaining forced age after becoming adult
        if (self.age == 0 and self.forced_age != 0) {
            self.age = self.forced_age;
        }
    }

    /// Set breeding cooldown after mating
    pub fn setBreedingCooldown(self: *Age) void {
        self.age = 6000; // 5 minutes
    }

    /// Tick the age system (called each game tick)
    /// Returns true if crossed baby/adult boundary
    pub fn tick(self: *Age) bool {
        const was_baby = self.isBaby();

        // Handle forced age particle timer
        if (self.forced_age_timer > 0) {
            self.forced_age_timer -= 1;
        }

        // Age progression
        if (self.age < 0) {
            // Baby: age toward 0 (growing up)
            self.age += 1;
        } else if (self.age > 0) {
            // Adult with breeding cooldown: age toward 0
            self.age -= 1;
        }

        // Return true if crossed boundary
        return was_baby != self.isBaby();
    }
};
