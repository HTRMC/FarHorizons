const std = @import("std");
const zlm = @import("zlm");
const GameState = @import("../GameState.zig");
const Entity = GameState.Entity;
const Item = GameState.Item;
const BlockState = @import("../WorldState.zig").BlockState;

pub fn takeDamage(self: *GameState, amount: f32) void {
    if (self.game_mode != .survival or self.combat.damage_cooldown > 0) return;
    self.combat.health = @max(self.combat.health - amount, 0.0);
    self.combat.damage_cooldown = GameState.DAMAGE_COOLDOWN_TICKS;
    if (self.combat.health <= 0.0) die(self);
}

pub fn dropInventoryWithScatter(self: *GameState, slots: []Entity.ItemStack, pos: [3]f32, random: std.Random) void {
    for (slots) |*stack| {
        if (!stack.isEmpty()) {
            spawnScatterDrop(self, pos, stack.*, random);
            stack.* = Entity.ItemStack.EMPTY;
        }
    }
}

pub fn spawnScatterDrop(self: *GameState, pos: [3]f32, item: Entity.ItemStack, random: std.Random) void {
    const prev_count = self.entities.count;
    self.entities.spawnItemDropWithDurability(pos, item.block, item.count, item.durability);
    if (self.entities.count <= prev_count) return;

    // MC death scatter: random direction, random speed 0-0.5, upward 0.2
    const last = self.entities.count - 1;
    const speed = random.float(f32) * 0.5;
    const angle = random.float(f32) * std.math.tau;
    self.entities.vel[last] = .{
        -@sin(angle) * speed,
        0.2,
        @cos(angle) * speed,
    };
    self.entities.pickup_cooldown[last] = GameState.DEATH_DROP_PICKUP_COOLDOWN;
}

pub fn die(self: *GameState) void {
    const P = Entity.PLAYER;
    const death_pos = self.entities.pos[P];
    const inv = self.playerInv();

    // Drop all inventory items with MC-style random radial explosion
    var rng = std.Random.DefaultPrng.init(@bitCast(self.game_time));
    const random = rng.random();
    dropInventoryWithScatter(self, &inv.hotbar, death_pos, random);
    dropInventoryWithScatter(self, &inv.main, death_pos, random);
    if (!inv.offhand.isEmpty()) {
        spawnScatterDrop(self, death_pos, inv.offhand, random);
        inv.offhand = Entity.ItemStack.EMPTY;
    }

    // Respawn at world spawn
    const spawn = GameState.findSpawn(self.streaming.world_seed);
    self.entities.pos[P] = spawn;
    self.entities.prev_pos[P] = spawn;
    self.entities.vel[P] = .{ 0, 0, 0 };
    self.entities.flags[P].on_ground = true;
    self.camera.position = zlm.Vec3.init(spawn[0], spawn[1] + GameState.EYE_OFFSET, spawn[2]);
    self.prev_camera_pos = self.camera.position;
    self.tick_camera_pos = self.camera.position;

    self.combat.health = self.combat.max_health;
    self.combat.air_supply = self.combat.max_air;
    self.combat.damage_cooldown = GameState.RESPAWN_IMMUNITY_TICKS;
    self.combat.was_on_ground = true;
    self.combat.fall_start_y = spawn[1];
}

pub fn updateFallDamage(self: *GameState) void {
    if (self.game_mode != .survival) return;
    const P = Entity.PLAYER;
    const flags = self.entities.flags[P];
    const pos_y = self.entities.pos[P][1];

    if (!self.combat.was_on_ground and flags.on_ground and !flags.in_water) {
        const damage = self.combat.fall_start_y - pos_y - 3.0;
        if (damage > 0) takeDamage(self, damage);
    }

    if (flags.on_ground or flags.in_water) {
        self.combat.fall_start_y = pos_y;
    } else {
        self.combat.fall_start_y = @max(self.combat.fall_start_y, pos_y);
    }

    self.combat.was_on_ground = flags.on_ground;
}

pub fn updateDrowning(self: *GameState) void {
    if (self.game_mode != .survival) return;
    const P = Entity.PLAYER;
    if (self.entities.flags[P].eyes_in_water) {
        if (self.combat.air_supply > 0) {
            self.combat.air_supply -= 1;
        } else {
            // Drowning damage: 1 HP every 30 ticks (1 second)
            if (@mod(self.game_time, 30) == 0) {
                takeDamage(self, 1.0);
            }
        }
    } else {
        self.combat.air_supply = @min(self.combat.air_supply + 5, self.combat.max_air);
    }
}

pub fn updateCombatSystems(self: *GameState) void {
    if (self.combat.damage_cooldown > 0) self.combat.damage_cooldown -= 1;
    if (self.combat.entity_attack_cooldown > 0) self.combat.entity_attack_cooldown -= 1;
    if (self.mode == .walking) {
        updateFallDamage(self);
        updateDrowning(self);
    }
    updateBreakProgress(self);
    updateAttackDamage(self);
}

pub fn updateBreakProgress(self: *GameState) void {
    if (self.game_mode != .survival) return;
    if (!self.combat.attack_held) {
        if (self.combat.break_progress > 0) {
            self.combat.break_progress = 0;
            self.combat.breaking_pos = null;
        }
        return;
    }

    const hit = self.hit_result orelse {
        self.combat.break_progress = 0;
        self.combat.breaking_pos = null;
        return;
    };

    const target_pos = hit.block_pos;

    // Reset if target changed
    if (self.combat.breaking_pos) |bp| {
        if (bp[0] != target_pos[0] or bp[1] != target_pos[1] or bp[2] != target_pos[2]) {
            self.combat.break_progress = 0;
        }
    }
    self.combat.breaking_pos = target_pos;

    const block_state = self.chunk_map.getBlock(target_pos[0], target_pos[1], target_pos[2]);
    const hardness = BlockState.getHardness(block_state);

    // Unbreakable
    if (hardness < 0) return;

    // Instant break
    if (hardness == 0) {
        self.breakBlock();
        self.combat.break_progress = 0;
        self.combat.breaking_pos = null;
        return;
    }

    // Calculate tool multiplier
    var tool_multiplier: f32 = 1.0;
    const held_slot = self.playerInv().hotbar[self.inv.selected_slot];
    if (held_slot.isTool()) {
        if (Item.toolFromId(held_slot.block)) |tool_info| {
            const preferred = BlockState.getPreferredTool(block_state);
            if (preferred != null and preferred.? == tool_info.tool_type) {
                tool_multiplier = Item.tierStats(tool_info.tier).mining_speed;
            }
        }
    }

    const break_time = hardness * GameState.BREAK_TIME_MULTIPLIER / tool_multiplier;
    const speed_per_tick = 1.0 / (break_time * GameState.TICK_RATE);
    self.combat.break_progress += speed_per_tick;

    if (self.combat.break_progress >= 1.0) {
        // Check if tool can harvest (requires_tool check)
        const can_harvest = !BlockState.requiresTool(block_state) or (tool_multiplier > 1.0);
        if (!can_harvest) {
            // Break the block but don't drop it
            self.breakBlockNoDrop();
        } else {
            self.breakBlock();
        }

        // Durability cost
        if (held_slot.isTool()) {
            const slot = &self.playerInv().hotbar[self.inv.selected_slot];
            if (slot.durability > 1) {
                slot.durability -= 1;
            } else {
                slot.* = Entity.ItemStack.EMPTY;
            }
        }

        self.combat.break_progress = 0;
        self.combat.breaking_pos = null;
    }
}

pub fn updateAttackDamage(self: *GameState) void {
    const held = self.playerInv().hotbar[self.inv.selected_slot];
    if (held.isTool()) {
        if (Item.toolFromId(held.block)) |info| {
            self.combat.attack_damage = Item.baseAttackDamage(info.tool_type) + Item.tierStats(info.tier).attack_bonus;
            return;
        }
    }
    self.combat.attack_damage = 1.0;
}

pub fn attackEntity(self: *GameState) bool {
    if (self.combat.entity_attack_cooldown > 0) return false;

    const eh = self.entity_hit orelse return false;
    const id = eh.entity_id;
    if (id >= self.entities.count) return false;
    if (self.entities.kind[id] != .pig) return false;

    // Only attack if entity is closer than any block hit
    if (self.hit_result) |block_hit| {
        const cam = self.camera.position;
        const bx = @as(f32, @floatFromInt(block_hit.block_pos[0])) + 0.5;
        const by = @as(f32, @floatFromInt(block_hit.block_pos[1])) + 0.5;
        const bz = @as(f32, @floatFromInt(block_hit.block_pos[2])) + 0.5;
        const dx = bx - cam.x;
        const dy = by - cam.y;
        const dz = bz - cam.z;
        if (eh.distance > @sqrt(dx * dx + dy * dy + dz * dz)) return false;
    }

    self.swing_requested = true;
    self.combat.entity_attack_cooldown = GameState.ATTACK_COOLDOWN_TICKS;

    // Apply damage
    self.entities.mob_health[id] -= self.combat.attack_damage;
    self.entities.hurt_time[id] = 10;

    // Knockback: push away from player
    const player_pos = self.entities.pos[Entity.PLAYER];
    const mob_pos = self.entities.pos[id];
    var kx = mob_pos[0] - player_pos[0];
    var kz = mob_pos[2] - player_pos[2];
    const len = @sqrt(kx * kx + kz * kz);
    if (len > 0.001) {
        kx /= len;
        kz /= len;
    } else {
        kx = 0;
        kz = 1;
    }
    const knockback_strength: f32 = GameState.KNOCKBACK_STRENGTH;
    self.entities.vel[id][0] += kx * knockback_strength;
    self.entities.vel[id][1] = GameState.KNOCKBACK_UPWARD;
    self.entities.vel[id][2] += kz * knockback_strength;
    return true;
}
