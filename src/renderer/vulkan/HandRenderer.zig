const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;
const app_config = @import("../../app_config.zig");
const EntityVertex = @import("EntityRenderer.zig").EntityVertex;
const WorldState = @import("../../world/WorldState.zig");
const BlockState = WorldState.BlockState;
const Item = @import("../../Item.zig");
const Io = std.Io;
const Dir = Io.Dir;

const MAX_VERTICES = 512; // arm (36) + block (36) + headroom

const PushConstants = extern struct {
    mvp: [16]f32,
    use_block_texture: i32,
    tex_layer: i32,
    _pad0: i32 = 0,
    _pad1: i32 = 0,
    ambient_light: [3]f32,
    contrast: f32,
    sun_dir: [3]f32,
    sky_level: f32,
    block_light: [3]f32,
    _pad2: f32 = 0,
};

pub const HandRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_alloc: BufferAllocation,
    gpu_alloc: *GpuAllocator,
    arm_vertex_count: u32 = 0,
    block_vertex_start: u32 = 0,
    block_vertex_count: u32 = 0,
    visible: bool = true,
    walk_phase: f32 = 0.0,
    walk_smoother: f32 = 0.0,
    bob_pitch: f32 = 0.0,
    bob_yaw: f32 = 0.0,
    cam_pitch: f32 = 0.0,
    cam_yaw: f32 = 0.0,
    swing_progress: f32 = 0.0,
    swing_ticks: f32 = 0.0,
    is_swinging: bool = false,
    equip_progress: f32 = 1.0,
    idle_tick: f32 = 0.0,
    pending_block: BlockState.StateId = BlockState.defaultState(.air),
    block_tex_top: i16 = -1,
    block_tex_side: i16 = -1,
    held_block: BlockState.StateId = BlockState.defaultState(.air),
    is_shaped: bool = false,
    tex_groups: [8]TexGroup = undefined,
    tex_group_count: u8 = 0,

    const TexGroup = struct { start: u32, count: u32, tex_layer: i16 };

    pub fn init(
        allocator: std.mem.Allocator,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
        gpu_alloc: *GpuAllocator,
        skin_image_view: vk.VkImageView,
        skin_sampler: vk.VkSampler,
        block_tex_view: vk.VkImageView,
        block_tex_sampler: vk.VkSampler,
    ) !HandRenderer {
        const tz = tracy.zone(@src(), "HandRenderer.init");
        defer tz.end();

        var self = HandRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_alloc = undefined,
            .gpu_alloc = gpu_alloc,
        };

        try self.createResources(ctx, gpu_alloc, skin_image_view, skin_sampler, block_tex_view, block_tex_sampler);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.buildGeometry(allocator);

        return self;
    }

    pub fn deinit(self: *HandRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        self.gpu_alloc.destroyBuffer(self.vertex_alloc);
    }

    pub fn updateAnimations(self: *HandRenderer, dt: f32, horizontal_speed: f32, vertical_speed: f32, on_ground: bool, cam_pitch: f32, cam_yaw: f32) void {
        self.idle_tick += dt * 30.0;

        const speed_threshold: f32 = 1.6;
        const vert_threshold: f32 = 1.6;
        const smooth_rate: f32 = 3.0;
        const walking = horizontal_speed > speed_threshold and @abs(vertical_speed) < vert_threshold and on_ground;

        if (walking) {
            self.walk_phase += horizontal_speed * dt * 1.5;
            self.walk_smoother = @min(1.0, self.walk_smoother + smooth_rate * dt);
        } else {
            self.walk_smoother = @max(0.0, self.walk_smoother - smooth_rate * dt);
        }

        self.cam_pitch = cam_pitch;
        self.cam_yaw = cam_yaw;
        const bob_rate = @min(1.0, 15.0 * dt);
        self.bob_pitch += (cam_pitch - self.bob_pitch) * bob_rate;
        self.bob_yaw += (cam_yaw - self.bob_yaw) * bob_rate;

        if (self.is_swinging) {
            self.swing_ticks += dt * 30.0;
            if (self.swing_ticks >= 9.0) {
                self.swing_ticks = 0.0;
                self.swing_progress = 0.0;
                self.is_swinging = false;
            } else {
                self.swing_progress = self.swing_ticks / 9.0;
            }
        }

        const equip_rate: f32 = 8.0 * dt;
        if (self.pending_block != self.held_block) {
            self.equip_progress = @max(0.0, self.equip_progress - equip_rate);
            if (self.equip_progress < 0.05) {
                self.updateHeldBlock(self.pending_block);
                self.equip_progress = 0.0;
            }
        } else {
            self.equip_progress = @min(1.0, self.equip_progress + equip_rate);
        }
    }

    /// Trigger an arm swing (call on block break/place).
    pub fn triggerSwing(self: *HandRenderer) void {
        if (!self.is_swinging) {
            self.is_swinging = true;
            self.swing_ticks = 0.0;
            self.swing_progress = 0.0;
        }
    }

    /// Set the pending block (equip animation will swap when arm is lowered).
    pub fn setPendingBlock(self: *HandRenderer, state: BlockState.StateId) void {
        self.pending_block = state;
    }

    pub fn recordDraw(self: *const HandRenderer, command_buffer: vk.VkCommandBuffer, screen_width: f32, screen_height: f32, third_person: bool, ambient_light: [3]f32, sun_dir: [3]f32, sky_level: f32, block_light: [3]f32) void {
        if (!self.visible or third_person) return;
        if (self.arm_vertex_count == 0) return;

        const has_block = self.block_tex_side >= 0;

        // Clear depth in full viewport so hand renders on top of world
        const full_scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(@max(screen_width, 1)),
                .height = @intFromFloat(@max(screen_height, 1)),
            },
        };
        const clear_attachment = vk.VkClearAttachment{
            .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
            .colorAttachment = 0,
            .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const clear_rect = vk.VkClearRect{
            .rect = full_scissor,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        vk.cmdClearAttachments(command_buffer, 1, &[_]vk.VkClearAttachment{clear_attachment}, 1, &[_]vk.VkClearRect{clear_rect});

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);

        const aspect = screen_width / @max(screen_height, 1.0);
        const proj = zlm.Mat4.perspective(std.math.degreesToRadians(70.0), aspect, 0.05, 100.0);

        const view_bob_x = mat4RotX((self.bob_pitch - self.cam_pitch) * 0.1);
        const view_bob_y = mat4RotY((self.bob_yaw - self.cam_yaw) * 0.1);
        const view_bob_mat = zlm.Mat4.mul(view_bob_x, view_bob_y);

        var walk_mat = zlm.Mat4.identity();
        if (self.walk_smoother > 0.001) {
            const ws = self.walk_smoother;
            const wp = self.walk_phase;
            const wl: f32 = -1.0;
            const walk_val = wp - 0.75;
            const t_to_pivot = mat4Translate(0, -0.4, 0);
            const t_from_pivot = mat4Translate(0, 0.4, 0);
            const d = std.math.degreesToRadians;
            walk_mat = t_to_pivot;
            walk_mat = zlm.Mat4.mul(walk_mat, mat4RotX(d(1.5 * @sin(walk_val) * ws)));
            walk_mat = zlm.Mat4.mul(walk_mat, mat4RotY(d(-0.5 * @cos(wp * 1.5) * ws * wl)));
            walk_mat = zlm.Mat4.mul(walk_mat, mat4RotZ(d(1.0 * @cos(wp * 1.5) * ws * wl)));
            walk_mat = zlm.Mat4.mul(walk_mat, t_from_pivot);
        }

        const deg = std.math.degreesToRadians;

        const idle_t = self.idle_tick * 0.04;
        const ipx: f32 = 0.3;
        const ipy: f32 = -0.4;
        const ipz: f32 = 0.0;
        var idle_mat = mat4Translate(0, 0.01 * @sin(idle_t), 0);
        idle_mat = zlm.Mat4.mul(idle_mat, rotateAround(mat4RotX(deg(-1.1 * @cos(idle_t))), ipx, ipy, ipz));
        idle_mat = zlm.Mat4.mul(idle_mat, rotateAround(mat4RotY(deg(0.5 * @sin(idle_t))), ipx, ipy, ipz));
        idle_mat = zlm.Mat4.mul(idle_mat, rotateAround(mat4RotZ(deg(2.0 * @sin(idle_t * 0.3))), ipx, ipy, ipz));

        const l: f32 = 1.0;
        const attack_value: f32 = self.swing_progress;
        const inverse_arm_height: f32 = 1.0 - self.equip_progress;

        const sqrt_attack = @sqrt(attack_value);
        const x_swing_pos = -0.3 * @sin(sqrt_attack * std.math.pi);
        const y_swing_pos = 0.4 * @sin(sqrt_attack * (std.math.pi * 2.0));
        const z_swing_pos = -0.4 * @sin(attack_value * std.math.pi);

        var scene_mat = zlm.Mat4.mul(view_bob_mat, walk_mat);
        scene_mat = zlm.Mat4.mul(scene_mat, idle_mat);
        scene_mat = zlm.Mat4.mul(scene_mat, mat4Translate(l * x_swing_pos, y_swing_pos, z_swing_pos));
        if (has_block) {
            scene_mat = zlm.Mat4.mul(scene_mat, mat4Translate(0, -0.35, 0.2));
        }

        // Arm matrix: scene_mat → mainHandPose → arm bone chain
        var m = scene_mat;

        if (has_block) {
            m = zlm.Mat4.mul(m, mat4Translate(1.5 * l, -0.3, -0.6));
            m = zlm.Mat4.mul(m, rotateAround(mat4RotX(deg(15.0)), 0.5 * l, 0.5, 0.5));
            m = zlm.Mat4.mul(m, rotateAround(mat4RotY(deg(35.0 * l)), 0.5 * l, 0.5, 0.5));
            m = zlm.Mat4.mul(m, rotateAround(mat4RotZ(deg(-65.0 * l)), 0.5 * l, 0.5, 0.5));
            m = zlm.Mat4.mul(m, mat4Scale(0.9, 0.9, 0.9));
        }

        m = zlm.Mat4.mul(m, mat4Translate(
            l * 0.64000005,
            -0.6 + inverse_arm_height * -0.6,
            -0.71999997,
        ));
        m = zlm.Mat4.mul(m, mat4RotY(deg(l * 45.0)));

        const z_swing_rot = @sin(attack_value * attack_value * std.math.pi);
        const y_swing_rot = @sin(sqrt_attack * std.math.pi);
        m = zlm.Mat4.mul(m, mat4RotY(deg(l * y_swing_rot * 70.0)));
        m = zlm.Mat4.mul(m, mat4RotZ(deg(l * z_swing_rot * -20.0)));

        m = zlm.Mat4.mul(m, mat4Translate(l * -1.0, 3.6, 3.5));
        m = zlm.Mat4.mul(m, mat4RotZ(deg(l * 120.0)));
        m = zlm.Mat4.mul(m, mat4RotX(deg(200.0)));
        m = zlm.Mat4.mul(m, mat4RotY(deg(l * -135.0)));
        m = zlm.Mat4.mul(m, mat4Translate(l * 5.6, 0.0, 0.0));

        {
            const mc_scale: f32 = 10.0 / 9.0;
            const s_pre = mat4Scale(mc_scale, -mc_scale, mc_scale);
            const t_cube = mat4Translate(-0.0625, -0.125, 0);
            const t_part = mat4Translate(-0.3125, 0.125, 0);
            const r_part = mat4RotZ(0.1);
            var pre = zlm.Mat4.mul(t_cube, s_pre);
            pre = zlm.Mat4.mul(r_part, pre);
            pre = zlm.Mat4.mul(t_part, pre);

            const arm_model = zlm.Mat4.mul(m, pre);
            const mvp = zlm.Mat4.mul(proj, arm_model);

            const pc = PushConstants{
                .mvp = mvp.m,
                .use_block_texture = 0,
                .tex_layer = 0,
                .ambient_light = ambient_light,
                .contrast = 0.25,
                .sun_dir = sun_dir,
                .sky_level = sky_level,
                .block_light = block_light,
            };
            vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
            vk.cmdDraw(command_buffer, self.arm_vertex_count, 1, 0, 0);
        }

        if (has_block) {
            const is_torch = BlockState.getBlock(self.held_block) == .torch;

            var block_model = zlm.Mat4.mul(scene_mat, mat4Translate(0.0, (1.0 - self.equip_progress) * -0.6, 0.0));
            block_model = zlm.Mat4.mul(block_model, mat4Translate(0.5 * l, -0.15, -0.85));
            block_model = zlm.Mat4.mul(block_model, rotateAround(mat4RotX(deg(15.0)), 0.5, 0.5, 0.5));
            block_model = zlm.Mat4.mul(block_model, mat4Scale(0.9, 0.9, 0.9));

            block_model = zlm.Mat4.mul(block_model, mat4Translate(0, 0, -0.05));
            if (!is_torch) {
                block_model = zlm.Mat4.mul(block_model, mat4Translate(0, -0.15, 0));
                block_model = zlm.Mat4.mul(block_model, mat4RotZ(deg(6.0 * l)));
                block_model = zlm.Mat4.mul(block_model, mat4RotX(deg(-8.0)));
            }
            block_model = zlm.Mat4.mul(block_model, mat4RotY(deg(25.0 * l)));
            block_model = zlm.Mat4.mul(block_model, mat4Scale(1.1, 1.1, 1.1));

            block_model = zlm.Mat4.mul(block_model, mat4Translate(0.22 * l, 0.25, 0.2));

            if (is_torch) {
                block_model = zlm.Mat4.mul(block_model, mat4Translate(-0.05 * l, 0.0, 0.0));
                block_model = zlm.Mat4.mul(block_model, mat4Scale(1.75, 1.75, 1.75));
            } else {
                block_model = zlm.Mat4.mul(block_model, mat4Translate(-0.25 * l, -0.05, 0.0));
            }

            block_model = zlm.Mat4.mul(block_model, mat4Scale(0.3, 0.3, 0.3));
            block_model = zlm.Mat4.mul(block_model, mat4Translate(-0.9 * l, -0.45, -0.7));
            block_model = zlm.Mat4.mul(block_model, mat4Translate(0.5, 0.5, 0.5));

            const mvp = zlm.Mat4.mul(proj, block_model);

            if (self.is_shaped) {
                // Shaped block: draw per-texture groups
                for (self.tex_groups[0..self.tex_group_count]) |group| {
                    const pc = PushConstants{
                        .mvp = mvp.m,
                        .use_block_texture = 1,
                        .tex_layer = group.tex_layer,
                        .ambient_light = ambient_light,
                        .contrast = 0.25,
                        .sun_dir = sun_dir,
                        .sky_level = sky_level,
                        .block_light = block_light,
                    };
                    vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
                    vk.cmdDraw(command_buffer, group.count, 1, group.start, 0);
                }
            } else {
                // Full cube: draw 4 side faces (24 verts) with side texture
                const pc_side = PushConstants{
                    .mvp = mvp.m,
                    .use_block_texture = 1,
                    .tex_layer = self.block_tex_side,
                    .ambient_light = ambient_light,
                    .contrast = 0.25,
                    .sun_dir = sun_dir,
                    .sky_level = sky_level,
                    .block_light = block_light,
                };
                vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc_side));
                vk.cmdDraw(command_buffer, 24, 1, self.block_vertex_start, 0);

                // Draw top + bottom faces (12 verts) with top texture
                const pc_top = PushConstants{
                    .mvp = mvp.m,
                    .use_block_texture = 1,
                    .tex_layer = self.block_tex_top,
                    .ambient_light = ambient_light,
                    .contrast = 0.25,
                    .sun_dir = sun_dir,
                    .sky_level = sky_level,
                    .block_light = block_light,
                };
                vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc_top));
                vk.cmdDraw(command_buffer, 12, 1, self.block_vertex_start + 24, 0);
            }
        }
    }

    /// Update the held block, rebuilding geometry if the shape changes.
    pub fn updateHeldBlock(self: *HandRenderer, state: BlockState.StateId) void {
        if (state == self.held_block) return;
        self.held_block = state;

        // Tools don't have block textures — render as empty hand
        if (Item.isToolItem(state)) {
            self.block_tex_top = -1;
            self.block_tex_side = -1;
            self.is_shaped = false;
            return;
        }

        const tex = BlockState.blockTexIndices(state);
        self.block_tex_top = tex.top;
        self.block_tex_side = tex.side;

        if (BlockState.getBlock(state) == .air) {
            self.is_shaped = false;
            return;
        }

        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));
        var count = self.block_vertex_start;

        if (BlockState.isShaped(state)) {
            self.is_shaped = true;
            count = self.buildShapedBlock(vertices, count, state);
        } else {
            self.is_shaped = false;
            count = buildUnitBlock(vertices, count);
        }
        self.block_vertex_count = count - self.block_vertex_start;
    }

    // ============================================================
    // Geometry building
    // ============================================================

    fn buildGeometry(self: *HandRenderer, allocator: std.mem.Allocator) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));
        var count: u32 = 0;

        // Build right arm from player.json
        count = self.buildArmGeometry(allocator, vertices, count);
        self.arm_vertex_count = count;

        // Build unit block (1x1x1 cube at origin with 0-1 UVs)
        self.block_vertex_start = count;
        count = buildUnitBlock(vertices, count);
        self.block_vertex_count = count - self.block_vertex_start;

        std.log.info("Hand geometry: {} arm verts, {} block verts", .{ self.arm_vertex_count, self.block_vertex_count });
    }

    fn buildArmGeometry(self: *HandRenderer, allocator: std.mem.Allocator, vertices: [*]EntityVertex, start: u32) u32 {
        _ = self;
        const sep = std.fs.path.sep_str;
        const assets_path = app_config.getAssetsPath(allocator) catch return start;
        defer allocator.free(assets_path);

        const model_path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "models" ++ sep ++ "player.json", .{assets_path}, 0) catch return start;
        defer allocator.free(model_path);

        const io = Io.Threaded.global_single_threaded.io();
        const data = Dir.readFileAlloc(.cwd(), io, model_path, allocator, .unlimited) catch return start;
        defer allocator.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return start;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return start,
        };

        const tex_size = switch (root.get("texture_size") orelse return start) {
            .array => |arr| arr.items,
            else => return start,
        };
        const tex_w: f32 = @floatCast(jf(tex_size[0]));
        const tex_h: f32 = @floatCast(jf(tex_size[1]));

        const parts = switch (root.get("parts") orelse return start) {
            .array => |arr| arr.items,
            else => return start,
        };

        // Use same scale as EntityRenderer (TARGET_HEIGHT = 1.8)
        const TARGET_HEIGHT = 1.8;
        var min_y: f64 = std.math.inf(f64);
        var max_y: f64 = -std.math.inf(f64);
        for (parts) |pv| {
            const p = switch (pv) { .object => |obj| obj, else => continue };
            const min_arr = switch (p.get("min") orelse continue) { .array => |a| a.items, else => continue };
            const size_arr = switch (p.get("size") orelse continue) { .array => |a| a.items, else => continue };
            if (min_arr.len < 3 or size_arr.len < 3) continue;
            min_y = @min(min_y, jf(min_arr[1]));
            max_y = @max(max_y, jf(min_arr[1]) + jf(size_arr[1]));
        }
        const model_height = max_y - min_y;
        if (model_height <= 0) return start;
        const scale: f64 = TARGET_HEIGHT / model_height;

        var count = start;

        // Only build the "right_arm" part
        for (parts) |pv| {
            const p = switch (pv) { .object => |obj| obj, else => continue };
            const name_val = p.get("name") orelse continue;
            const name = switch (name_val) { .string => |s| s, else => continue };
            if (!std.mem.eql(u8, name, "right_arm")) continue;

            const min_arr = switch (p.get("min") orelse continue) { .array => |a| a.items, else => continue };
            const size_arr = switch (p.get("size") orelse continue) { .array => |a| a.items, else => continue };
            const uv_arr = switch (p.get("uv") orelse continue) { .array => |a| a.items, else => continue };
            if (min_arr.len < 3 or size_arr.len < 3 or uv_arr.len < 2) continue;

            // Center the arm: x/z centered, shoulder at y=0, hand extends to -Y
            const arm_center_x: f64 = jf(min_arr[0]) + jf(size_arr[0]) / 2.0;
            const arm_top_y: f64 = jf(min_arr[1]) + jf(size_arr[1]);
            const arm_center_z: f64 = jf(min_arr[2]) + jf(size_arr[2]) / 2.0;

            const bx: f32 = @floatCast((jf(min_arr[0]) - arm_center_x) * scale);
            const by: f32 = @floatCast((jf(min_arr[1]) - arm_top_y) * scale);
            const bz: f32 = @floatCast((jf(min_arr[2]) - arm_center_z) * scale);
            const bw: f32 = @floatCast(jf(size_arr[0]) * scale);
            const bh: f32 = @floatCast(jf(size_arr[1]) * scale);
            const bd: f32 = @floatCast(jf(size_arr[2]) * scale);

            const pw: f32 = @floatCast(jf(size_arr[0]));
            const ph: f32 = @floatCast(jf(size_arr[1]));
            const pd: f32 = @floatCast(jf(size_arr[2]));
            const tu: f32 = @floatCast(jf(uv_arr[0]));
            const tv: f32 = @floatCast(jf(uv_arr[1]));

            count = addTexturedBox(vertices, count, bx, by, bz, bw, bh, bd, tu, tv, pw, ph, pd, tex_w, tex_h, true);
            break;
        }

        return count;
    }

    /// Build a unit cube (1x1x1) centered at origin with 0-1 UVs.
    /// Order: 4 side faces (front, back, right, left = 24 verts), then top + bottom (12 verts).
    fn buildUnitBlock(vertices: [*]EntityVertex, start: u32) u32 {
        var count = start;
        const s: f32 = 0.5;

        // Front face (z+)
        count = addQuad(vertices, count, -s, -s, s, s, -s, s, s, s, s, -s, s, s, 0, 0, 1, 0, 1, 1, 0, false);
        // Back face (z-)
        count = addQuad(vertices, count, s, -s, -s, -s, -s, -s, -s, s, -s, s, s, -s, 0, 0, -1, 0, 1, 1, 0, false);
        // Right face (x+)
        count = addQuad(vertices, count, s, -s, s, s, -s, -s, s, s, -s, s, s, s, 1, 0, 0, 0, 1, 1, 0, false);
        // Left face (x-)
        count = addQuad(vertices, count, -s, -s, -s, -s, -s, s, -s, s, s, -s, s, -s, -1, 0, 0, 0, 1, 1, 0, false);
        // Top face (y+)
        count = addQuad(vertices, count, -s, s, s, s, s, s, s, s, -s, -s, s, -s, 0, 1, 0, 0, 1, 1, 0, false);
        // Bottom face (y-)
        count = addQuad(vertices, count, -s, -s, -s, s, -s, -s, s, -s, s, -s, -s, s, 0, -1, 0, 0, 1, 1, 0, false);

        return count;
    }

    /// Build geometry for a shaped block, grouped by texture layer.
    /// For doors, both bottom and top halves are combined into one model.
    fn buildShapedBlock(self: *HandRenderer, vertices: [*]EntityVertex, start: u32, state: BlockState.StateId) u32 {
        const registry = WorldState.getRegistry();

        // For doors, render both bottom and top halves scaled to fit
        const is_door = BlockState.isDoor(state) and BlockState.isDoorBottom(state);
        const part_count: u8 = if (is_door) 2 else 1;
        const parts = [2]BlockState.StateId{ state, if (is_door) BlockState.doorBottomToTop(state) else state };

        // First pass: collect unique texture layers across all parts
        var tex_layers: [8]i16 = undefined;
        var n_tex: u8 = 0;
        for (0..part_count) |pi| {
            const part_faces = WorldState.getShapeFaces(parts[pi]);
            const part_tex = WorldState.getShapedTexIndices(parts[pi]);
            for (0..part_faces.len) |fi| {
                const tl: i16 = if (fi < part_tex.len) @intCast(part_tex[fi]) else self.block_tex_side;
                var found = false;
                for (tex_layers[0..n_tex]) |existing| {
                    if (existing == tl) { found = true; break; }
                }
                if (!found and n_tex < 8) {
                    tex_layers[n_tex] = tl;
                    n_tex += 1;
                }
            }
        }

        // Second pass: emit verts grouped by texture
        var count = start;
        self.tex_group_count = 0;
        for (tex_layers[0..n_tex]) |tl| {
            const group_start = count;
            for (0..part_count) |pi| {
                const part_faces = WorldState.getShapeFaces(parts[pi]);
                const part_tex = WorldState.getShapedTexIndices(parts[pi]);
                for (part_faces, 0..) |sf, fi| {
                    const face_tex: i16 = if (fi < part_tex.len) @intCast(part_tex[fi]) else self.block_tex_side;
                    if (face_tex != tl) continue;

                    const mi = sf.model_index;
                    if (mi < WorldState.EXTRA_MODEL_BASE) continue;
                    const em = registry.extra_models[@as(usize, mi) - WorldState.EXTRA_MODEL_BASE];

                    var v: [4]EntityVertex = undefined;
                    for (0..4) |ci| {
                        var py = em.corners[ci][1];
                        if (is_door) {
                            // Scale both halves to fit: bottom=[0,0.5], top=[0.5,1]
                            py = py * 0.5 + @as(f32, @floatFromInt(pi)) * 0.5;
                        }
                        v[ci] = .{
                            .px = em.corners[ci][0] - 0.5,
                            .py = py - 0.5,
                            .pz = em.corners[ci][2] - 0.5,
                            .nx = em.normal[0],
                            .ny = em.normal[1],
                            .nz = em.normal[2],
                            .u = em.uvs[ci][0],
                            .v = em.uvs[ci][1],
                        };
                    }
                    vertices[count] = v[0];
                    vertices[count + 1] = v[1];
                    vertices[count + 2] = v[2];
                    vertices[count + 3] = v[0];
                    vertices[count + 4] = v[2];
                    vertices[count + 5] = v[3];
                    count += 6;
                }
            }
            const group_count = count - group_start;
            if (group_count > 0 and self.tex_group_count < 8) {
                self.tex_groups[self.tex_group_count] = .{
                    .start = group_start,
                    .count = group_count,
                    .tex_layer = tl,
                };
                self.tex_group_count += 1;
            }
        }

        return count;
    }

    // Copied from EntityRenderer — Minecraft-style UV box layout
    fn addTexturedBox(
        vertices: [*]EntityVertex,
        start: u32,
        x: f32, y: f32, z: f32,
        w: f32, h: f32, d: f32,
        tu: f32, tv: f32,
        pw: f32, ph: f32, pd: f32,
        tw: f32, th: f32,
        reverse_winding: bool,
    ) u32 {
        var count = start;
        const x0 = x;
        const y0 = y;
        const z0 = z;
        const x1 = x + w;
        const y1 = y + h;
        const z1 = z + d;

        // Front face (z+)
        count = addQuad(vertices, count, x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1, 0, 0, 1, (tu + pd) / tw, (tv + pd + ph) / th, (tu + pd + pw) / tw, (tv + pd) / th, reverse_winding);
        // Back face (z-)
        count = addQuad(vertices, count, x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0, 0, 0, -1, (tu + 2 * pd + pw) / tw, (tv + pd + ph) / th, (tu + 2 * pd + 2 * pw) / tw, (tv + pd) / th, reverse_winding);
        // Right face (x+)
        count = addQuad(vertices, count, x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, (tu + pd + pw) / tw, (tv + pd + ph) / th, (tu + 2 * pd + pw) / tw, (tv + pd) / th, reverse_winding);
        // Left face (x-)
        count = addQuad(vertices, count, x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, tu / tw, (tv + pd + ph) / th, (tu + pd) / tw, (tv + pd) / th, reverse_winding);
        // Top face (y+)
        count = addQuad(vertices, count, x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, (tu + pd) / tw, tv / th, (tu + pd + pw) / tw, (tv + pd) / th, reverse_winding);
        // Bottom face (y-)
        count = addQuad(vertices, count, x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, (tu + pd + pw) / tw, tv / th, (tu + pd + 2 * pw) / tw, (tv + pd) / th, reverse_winding);

        return count;
    }

    fn addQuad(
        vertices: [*]EntityVertex,
        start: u32,
        x0: f32, y0: f32, z0: f32,
        x1: f32, y1: f32, z1: f32,
        x2: f32, y2: f32, z2: f32,
        x3: f32, y3: f32, z3: f32,
        nx: f32, ny: f32, nz: f32,
        uv_u0: f32, uv_v0: f32, uv_u1: f32, uv_v1: f32,
        reverse_winding: bool,
    ) u32 {
        const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 0 };

        var va = base;
        va.px = x0; va.py = y0; va.pz = z0; va.u = uv_u0; va.v = uv_v0;
        var vb = base;
        vb.px = x1; vb.py = y1; vb.pz = z1; vb.u = uv_u1; vb.v = uv_v0;
        var vc = base;
        vc.px = x2; vc.py = y2; vc.pz = z2; vc.u = uv_u1; vc.v = uv_v1;
        var vd = base;
        vd.px = x3; vd.py = y3; vd.pz = z3; vd.u = uv_u0; vd.v = uv_v1;

        if (reverse_winding) {
            // Swap winding: CW instead of CCW (compensates for odd-axis matrix flip)
            vertices[start] = va;
            vertices[start + 1] = vc;
            vertices[start + 2] = vb;
            vertices[start + 3] = va;
            vertices[start + 4] = vd;
            vertices[start + 5] = vc;
        } else {
            vertices[start] = va;
            vertices[start + 1] = vb;
            vertices[start + 2] = vc;
            vertices[start + 3] = va;
            vertices[start + 4] = vc;
            vertices[start + 5] = vd;
        }

        return start + 6;
    }

    fn jf(val: anytype) f64 {
        const v: std.json.Value = val;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => 0,
        };
    }

    // ============================================================
    // Matrix helpers (column-major for Vulkan/GLSL)
    // ============================================================

    fn mat4RotX(angle: f32) zlm.Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return zlm.Mat4{ .m = .{
            1, 0,  0, 0,
            0, c,  s, 0,
            0, -s, c, 0,
            0, 0,  0, 1,
        } };
    }

    fn mat4RotY(angle: f32) zlm.Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return zlm.Mat4{ .m = .{
            c,  0, -s, 0,
            0,  1,  0, 0,
            s,  0,  c, 0,
            0,  0,  0, 1,
        } };
    }

    fn mat4RotZ(angle: f32) zlm.Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return zlm.Mat4{ .m = .{
            c,  s, 0, 0,
            -s, c, 0, 0,
            0,  0, 1, 0,
            0,  0, 0, 1,
        } };
    }

    fn mat4Translate(tx: f32, ty: f32, tz: f32) zlm.Mat4 {
        return zlm.Mat4{ .m = .{
            1,  0,  0,  0,
            0,  1,  0,  0,
            0,  0,  1,  0,
            tx, ty, tz, 1,
        } };
    }

    fn mat4Scale(sx: f32, sy: f32, sz: f32) zlm.Mat4 {
        return zlm.Mat4{ .m = .{
            sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            0,  0,  0,  1,
        } };
    }

    fn rotateAround(rot: zlm.Mat4, ox: f32, oy: f32, oz: f32) zlm.Mat4 {
        const t_to = mat4Translate(ox, oy, oz);
        const t_from = mat4Translate(-ox, -oy, -oz);
        return zlm.Mat4.mul(zlm.Mat4.mul(t_to, rot), t_from);
    }

    // ============================================================
    // Vulkan resources
    // ============================================================

    fn createResources(
        self: *HandRenderer,
        ctx: *const VulkanContext,
        gpu_alloc: *GpuAllocator,
        skin_image_view: vk.VkImageView,
        skin_sampler: vk.VkSampler,
        block_tex_view: vk.VkImageView,
        block_tex_sampler: vk.VkSampler,
    ) !void {
        const vertex_buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(EntityVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        // Descriptor set layout: binding 0 = vertex SSBO, binding 1 = skin texture, binding 2 = block texture array
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null, .flags = 0,
            .bindingCount = 3,
            .pBindings = &bindings,
        }, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 },
        };

        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null, .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 2,
            .pPoolSizes = &pool_sizes,
        }, null);

        var sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, &sets);
        self.descriptor_set = sets[0];

        // Write descriptors
        const buffer_info = vk.VkDescriptorBufferInfo{ .buffer = self.vertex_alloc.buffer, .offset = 0, .range = vertex_buffer_size };
        const skin_desc_info = vk.VkDescriptorImageInfo{
            .sampler = skin_sampler,
            .imageView = skin_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const block_desc_info = vk.VkDescriptorImageInfo{
            .sampler = block_tex_sampler,
            .imageView = block_tex_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
                .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0,
                .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null, .pBufferInfo = &buffer_info, .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
                .dstSet = self.descriptor_set, .dstBinding = 1, .dstArrayElement = 0,
                .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &skin_desc_info, .pBufferInfo = null, .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
                .dstSet = self.descriptor_set, .dstBinding = 2, .dstArrayElement = 0,
                .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &block_desc_info, .pBufferInfo = null, .pTexelBufferView = null,
            },
        };
        vk.updateDescriptorSets(ctx.device, 3, &writes, 0, null);
    }

    fn createPipeline(self: *HandRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("entity.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("hand_block.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = vert_spirv.len, .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = frag_spirv.len, .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, frag_module, null);

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main", .pSpecializationInfo = null },
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main", .pSpecializationInfo = null },
        };

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .pNext = null, .flags = 0, .vertexBindingDescriptionCount = 0, .pVertexBindingDescriptions = null, .vertexAttributeDescriptionCount = 0, .pVertexAttributeDescriptions = null };
        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .pNext = null, .flags = 0, .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, .primitiveRestartEnable = vk.VK_FALSE };
        const viewport_state = vk.VkPipelineViewportStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .pNext = null, .flags = 0, .viewportCount = 1, .pViewports = null, .scissorCount = 1, .pScissors = null };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthClampEnable = vk.VK_FALSE, .rasterizerDiscardEnable = vk.VK_FALSE, .polygonMode = vk.VK_POLYGON_MODE_FILL, .cullMode = vk.VK_CULL_MODE_BACK_BIT, .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE, .depthBiasEnable = vk.VK_FALSE, .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0, .lineWidth = 1 };
        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .pNext = null, .flags = 0, .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT, .sampleShadingEnable = vk.VK_FALSE, .minSampleShading = 1, .pSampleMask = null, .alphaToCoverageEnable = vk.VK_FALSE, .alphaToOneEnable = vk.VK_FALSE };

        const depth_on = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_TRUE, .depthWriteEnable = vk.VK_TRUE, .depthCompareOp = vk.VK_COMPARE_OP_LESS, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };

        const blend_att = vk.VkPipelineColorBlendAttachmentState{ .blendEnable = vk.VK_FALSE, .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .colorBlendOp = vk.VK_BLEND_OP_ADD, .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .alphaBlendOp = vk.VK_BLEND_OP_ADD, .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT };
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0, .logicOpEnable = vk.VK_FALSE, .logicOp = 0, .attachmentCount = 1, .pAttachments = &blend_att, .blendConstants = .{ 0, 0, 0, 0 } };

        // Push constants: 64 bytes MVP (vertex) + 36 bytes fragment (useBlockTexture, texLayer, ambientLight, contrast, sunDir)
        const push_ranges = [_]vk.VkPushConstantRange{
            .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 64 },
            .{ .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 64, .size = @sizeOf(PushConstants) - 64 },
        };
        self.pipeline_layout = try vk.createPipelineLayout(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .setLayoutCount = 1, .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 2, .pPushConstantRanges = &push_ranges,
        }, null);

        const color_fmt = [_]vk.VkFormat{swapchain_format};
        const rendering_info = vk.VkPipelineRenderingCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = null, .viewMask = 0, .colorAttachmentCount = 1, .pColorAttachmentFormats = &color_fmt, .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT, .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED };

        const dyn_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dyn_info = vk.VkPipelineDynamicStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .pNext = null, .flags = 0, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rendering_info, .flags = 0,
            .stageCount = 2, .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info, .pInputAssemblyState = &input_assembly,
            .pTessellationState = null, .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer, .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_on, .pColorBlendState = &color_blending,
            .pDynamicState = @ptrCast(&dyn_info),
            .layout = self.pipeline_layout, .renderPass = null, .subpass = 0,
            .basePipelineHandle = null, .basePipelineIndex = -1,
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, &[1]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, &pipelines);
        self.pipeline = pipelines[0];

        std.log.info("Hand pipeline created", .{});
    }
};
