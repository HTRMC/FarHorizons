const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");
const platform = @import("Platform");
const renderer = @import("Renderer");
const world = @import("World");
const ecs = @import("ecs");
const block_interaction = @import("BlockInteraction.zig");
const BlockInteraction = block_interaction.BlockInteraction;
const entity_interaction = @import("EntityInteraction.zig");
const EntityInteraction = entity_interaction.EntityInteraction;
const Hotbar = @import("Hotbar.zig").Hotbar;
const profiler = shared.profiler;

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;
const Camera = shared.Camera;
const Mat4 = shared.Mat4;
const Vec3 = shared.Vec3;
const Chunk = shared.Chunk;
const BlockType = shared.BlockType;
const BlockEntry = shared.BlockEntry;
const CHUNK_SIZE = shared.CHUNK_SIZE;
const Window = platform.Window;
const DisplayData = platform.DisplayData;
const MouseHandler = platform.MouseHandler;
const KeyboardInput = platform.KeyboardInput;
const InputConstants = platform.InputConstants;
const RenderSystem = renderer.RenderSystem;
const Vertex = renderer.Vertex;
const TextureManager = renderer.TextureManager;
const BlockOutlineRenderer = renderer.BlockOutlineRenderer;
const ModelLoader = renderer.block.ModelLoader;
const FaceBakery = renderer.block.FaceBakery;
const BakedQuad = renderer.block.BakedQuad;
const Direction = renderer.block.Direction;
const BlockstateLoader = renderer.block.BlockstateLoader;
const BlockModelShaper = renderer.block.BlockModelShaper;
const ChunkManager = world.ChunkManager;
const ChunkConfig = world.chunk_manager.ChunkConfig;
const EntityRenderer = @import("entity/EntityRenderer.zig").EntityRenderer;
const EntityTextureManager = @import("entity/EntityTextureManager.zig").EntityTextureManager;

var terrain_query_cm: ?*ChunkManager = null;

fn terrainQueryFn(x: i32, y: i32, z: i32) shared.VoxelShape {
    if (terrain_query_cm) |cm| {
        return cm.getCollisionShape(x, y, z);
    }
    return shared.voxel_shape.EMPTY;
}

const volk = @import("volk");
const vk = volk.c;

/// Pre-render callback for GPU-driven chunk metadata uploads
fn preRenderMetadataUpload(cmd_buffer: vk.VkCommandBuffer, ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const cm: *ChunkManager = @ptrCast(@alignCast(ptr));
        cm.commitMetadataUploads(cmd_buffer);
    }
}

const VoxelDirection = shared.Direction;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    // Runs at 20 ticks per second (50ms per tick)
    const TICK_RATE: f64 = 20.0;
    const MS_PER_TICK: f64 = 1000.0 / TICK_RATE; // 50ms

    config: GameConfig,
    window: Window,
    mouse_handler: MouseHandler,
    keyboard_input: KeyboardInput,
    render_system: RenderSystem,
    texture_manager: ?TextureManager,
    chunk_manager: ?ChunkManager,
    camera: Camera,
    player_entity_id: ?ecs.EntityId,
    allocator: std.mem.Allocator,
    io: Io,
    use_async_chunks: bool,
    block_interaction: ?BlockInteraction,
    entity_interaction: ?EntityInteraction,
    block_outline_renderer: BlockOutlineRenderer,
    ecs_world: ?ecs.World,
    entity_renderer: ?EntityRenderer,
    entity_texture_manager: ?EntityTextureManager,
    cow_id: ?ecs.EntityId,
    baby_cow_id: ?ecs.EntityId,
    hotbar: Hotbar,

    pub fn init(allocator: std.mem.Allocator, config: GameConfig, io: Io) Self {
        const display_data = DisplayData{
            .width = @intCast(config.display.width),
            .height = @intCast(config.display.height),
            .fullscreen = config.display.fullscreen,
        };

        const camera = Camera.init();

        return Self{
            .config = config,
            .window = Window.init(display_data),
            .mouse_handler = undefined, // Initialized in run() after struct is at final location
            .keyboard_input = undefined, // Initialized in run() after struct is at final location
            .render_system = RenderSystem.init(allocator, io),
            .texture_manager = null, // Initialized in run() after render_system
            .chunk_manager = null, // Initialized in run() after texture_manager
            .camera = camera,
            .player_entity_id = null, // Initialized in run() after ecs_world
            .allocator = allocator,
            .io = io,
            .use_async_chunks = true,
            .block_interaction = null, // Initialized in run() after chunk_manager
            .entity_interaction = null, // Initialized in run() after ecs_world
            .block_outline_renderer = BlockOutlineRenderer.init(),
            .ecs_world = null,
            .entity_renderer = null,
            .entity_texture_manager = null,
            .cow_id = null,
            .baby_cow_id = null,
            .hotbar = Hotbar.initWithDefaults(),
        };
    }

    pub fn run(self: *Self) !void {
        profiler.setThreadName("MainThread");

        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});

        try platform.initBackend();
        defer platform.terminateBackend();

        // Create window first (needed for surface creation)
        try self.window.create("FarHorizons");
        defer self.window.destroy();

        // Initialize input handlers (must be done here after struct is at final location)
        self.mouse_handler = MouseHandler.init(&self.window);
        self.mouse_handler.setup();
        self.keyboard_input = KeyboardInput.init(&self.window);

        try self.render_system.initBackend(&self.window);
        defer self.render_system.shutdown();

        self.texture_manager = TextureManager.init(
            self.allocator,
            self.io,
            self.config.location.asset_directory,
            self.render_system.getDevice(),
            self.render_system.getPhysicalDevice(),
            self.render_system.getCommandPool(),
            self.render_system.getGraphicsQueue(),
        );
        try self.texture_manager.?.loadBlockTextures();
        defer self.texture_manager.?.deinit();

        try self.render_system.setTextureResources(
            self.texture_manager.?.getImageView(),
            self.texture_manager.?.getSampler(),
        );

        // Initialize hotbar icons with block textures
        try self.updateHotbarIcons();

        if (self.use_async_chunks) {
            self.chunk_manager = try ChunkManager.init(
                self.allocator,
                self.io,
                &self.render_system,
                &self.texture_manager.?,
                self.config.location.asset_directory,
                ChunkConfig{
                    .view_distance = 32,
                    .vertical_view_distance = 4,
                    .unload_distance = 34,
                    .worker_count = 10,
                    .max_uploads_per_tick = 64,
                },
            );
            try self.chunk_manager.?.start();
            // Update chunk manager with initial player position from ECS
            if (self.ecs_world) |*ecs_world| {
                if (self.player_entity_id) |pid| {
                    if (ecs_world.getComponent(ecs.Transform, pid)) |t| {
                        self.chunk_manager.?.updatePlayerPosition(t.position);
                    }
                }
            }
            self.block_interaction = BlockInteraction.init(&self.chunk_manager.?);

            // Set up pre-render callback for GPU-driven chunk metadata uploads
            self.render_system.setPreRenderCallback(preRenderMetadataUpload, &self.chunk_manager.?);

            logger.info("Async chunk loading enabled", .{});
        } else {
            try self.testModelLoading();
        }
        defer {
            if (self.chunk_manager) |*cm| {
                cm.deinit();
            }
        }

        // Render first frame before showing window (avoids white flash)
        self.render_system.drawFrame() catch |err| {
            logger.warn("Failed to render initial frame: {} - window may flash", .{err});
        };
        self.window.show();

        var esc_was_pressed = false;
        var timer = std.time.Timer.start() catch {
            logger.err("Failed to start timer", .{});
            return;
        };
        var tick_accumulator: f64 = 0;

        self.ecs_world = ecs.World.init(self.allocator);
        if (self.ecs_world) |*ecs_world| {
            try ecs.initSystems(ecs_world);

            // Spawn local player entity
            self.player_entity_id = try ecs.spawn.spawnLocalPlayer(ecs_world, Vec3{ .x = 8, .y = 100, .z = 20 });
            ecs_world.local_player_id = self.player_entity_id;

            // Set initial facing direction
            if (ecs_world.getComponentMut(ecs.Transform, self.player_entity_id.?)) |t| {
                t.yaw = 180; // Face towards -Z (towards the chunk)
            }
        }

        if (self.ecs_world) |*ecs_world| {
            self.entity_interaction = EntityInteraction.init(ecs_world);
        }

        self.entity_texture_manager = try EntityTextureManager.init(
            self.allocator,
            self.render_system.getDevice(),
            self.render_system.getPhysicalDevice(),
            self.render_system.getCommandPool(),
            self.render_system.getGraphicsQueue(),
        );

        const cow_tex_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/farhorizons/textures/entity/cow/cow.png",
            .{self.config.location.asset_directory},
        );
        defer self.allocator.free(cow_tex_path);

        const baby_cow_tex_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/farhorizons/textures/entity/cow/cow_baby.png",
            .{self.config.location.asset_directory},
        );
        defer self.allocator.free(baby_cow_tex_path);

        const cow_tex_index = try self.entity_texture_manager.?.loadTexture("cow", cow_tex_path);
        const baby_cow_tex_index = try self.entity_texture_manager.?.loadTexture("cow_baby", baby_cow_tex_path);

        logger.info("Loaded cow texture at index {}, baby cow at index {}", .{ cow_tex_index, baby_cow_tex_index });

        self.render_system.setBindlessEntityResources(
            self.entity_texture_manager.?.getDescriptorSetLayout(),
            self.entity_texture_manager.?.getDescriptorSet(),
        );
        try self.render_system.initEntityPipeline();

        self.entity_renderer = try EntityRenderer.initBindless(
            self.allocator,
            self.render_system.getGpuDevice().?,
            cow_tex_index,
            baby_cow_tex_index,
        );

        // Spawn above terrain - gravity will pull them down
        if (self.ecs_world) |*ecs_world| {
            self.cow_id = try ecs.spawn.spawnCow(ecs_world, Vec3{ .x = 9, .y = 100, .z = 9 });
            logger.info("Spawned adult cow with ECS entity ID", .{});

            self.baby_cow_id = try ecs.spawn.spawnBabyCow(ecs_world, Vec3{ .x = 12, .y = 100, .z = 10 });
            logger.info("Spawned baby cow with ECS entity ID", .{});
        }

        logger.info("Entering main loop", .{});
        while (!self.window.shouldClose()) {
            const frame_zone = profiler.traceNamed("Frame");
            defer frame_zone.end();

            const delta_ns = timer.lap();
            const delta_ms: f64 = @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
            tick_accumulator += delta_ms;

            platform.pollEvents();

            // Edge detection: only trigger on press, not hold
            const esc_pressed = self.window.isKeyPressed(InputConstants.KEY_ESCAPE);
            if (esc_pressed and !esc_was_pressed) {
                if (self.mouse_handler.isMouseGrabbed()) {
                    self.mouse_handler.releaseMouse();
                } else {
                    self.window.setShouldClose(true);
                }
            }
            esc_was_pressed = esc_pressed;

            // Mouse look is frame-rate independent, not tied to ticks
            if (self.mouse_handler.isMouseGrabbed()) {
                const rotation = self.mouse_handler.getCameraRotation();
                // Apply mouse rotation directly to ECS transform
                if (self.ecs_world) |*ecs_world| {
                    if (self.player_entity_id) |pid| {
                        if (ecs_world.getComponentMut(ecs.Transform, pid)) |t| {
                            t.yaw += @floatCast(rotation.yaw);
                            t.pitch = std.math.clamp(t.pitch + @as(f32, @floatCast(rotation.pitch)), -90.0, 90.0);
                        }
                    }
                }

                const scroll = self.mouse_handler.getAccumulatedScroll();
                if (scroll != 0) {
                    if (self.window.isKeyPressed(InputConstants.KEY_LEFT_SHIFT)) {
                        // Adjust flying speed via ECS component
                        if (self.ecs_world) |*ecs_world| {
                            if (self.player_entity_id) |pid| {
                                if (ecs_world.getComponentMut(ecs.components.PlayerAbilities, pid)) |abilities| {
                                    abilities.adjustFlyingSpeed(@floatCast(scroll));
                                }
                            }
                        }
                    } else {
                        // Scroll wheel changes hotbar selection
                        self.hotbar.scrollSlot(if (scroll > 0) 1 else -1);
                        self.render_system.setHotbarSelection(self.hotbar.getSelectedSlot());
                    }
                }
            }

            while (tick_accumulator >= MS_PER_TICK) {
                const tick_zone = profiler.traceNamed("GameTick");
                defer tick_zone.end();

                tick_accumulator -= MS_PER_TICK;

                // Update keyboard input state each tick
                self.keyboard_input.tick();

                // Number keys 1-9 for hotbar slot selection
                const number_keys = [_]c_int{
                    InputConstants.KEY_1, InputConstants.KEY_2, InputConstants.KEY_3,
                    InputConstants.KEY_4, InputConstants.KEY_5, InputConstants.KEY_6,
                    InputConstants.KEY_7, InputConstants.KEY_8, InputConstants.KEY_9,
                };
                for (number_keys, 0..) |key, i| {
                    if (self.window.isKeyPressed(key)) {
                        self.hotbar.selectSlot(@intCast(i));
                        self.render_system.setHotbarSelection(self.hotbar.getSelectedSlot());
                        break;
                    }
                }

                if (self.chunk_manager) |*cm| {
                    if (self.ecs_world) |*ecs_world| {
                        if (self.player_entity_id) |pid| {
                            if (ecs_world.getComponent(ecs.Transform, pid)) |t| {
                                cm.updatePlayerPosition(t.position);
                            }
                        }
                    }
                }

                if (self.block_interaction) |*bi| {
                    bi.tick();
                }

                if (self.entity_interaction) |*ei| {
                    ei.tick();
                }

                if (self.mouse_handler.isMouseGrabbed()) {
                    // Left click: try entity attack first, fall back to block breaking
                    if (self.mouse_handler.isLeftPressed()) {
                        var attacked_entity = false;
                        if (self.entity_interaction) |*ei| {
                            // Get player position from ECS
                            var player_pos = Vec3{ .x = 0, .y = 0, .z = 0 };
                            if (self.ecs_world) |*ecs_world| {
                                if (self.player_entity_id) |pid| {
                                    if (ecs_world.getComponent(ecs.Transform, pid)) |t| {
                                        player_pos = t.position;
                                    }
                                }
                            }
                            attacked_entity = ei.handleAttack(player_pos);
                        }
                        if (!attacked_entity) {
                            if (self.block_interaction) |*bi| {
                                _ = bi.handleLeftClick();
                            }
                        }
                    }
                    if (self.mouse_handler.isRightPressed()) {
                        if (self.block_interaction) |*bi| {
                            _ = bi.handleRightClick();
                        }
                    }
                    if (self.mouse_handler.isMiddlePressed()) {
                        if (self.block_interaction) |*bi| {
                            bi.handleMiddleClick();
                        }
                    }
                }

                // Tick ECS: runs physics, AI, animation, etc.
                if (self.ecs_world) |*ecs_world| {
                    terrain_query_cm = if (self.chunk_manager) |*cm| cm else null;
                    if (terrain_query_cm != null) {
                        ecs_world.setTerrainQuery(&terrainQueryFn);
                    }

                    // Pass current keyboard input to ECS before tick
                    const key_presses = self.keyboard_input.getKeyPresses();
                    const move_vec = self.keyboard_input.getMoveVector();
                    ecs_world.setCurrentInput(
                        move_vec.z, // forward/backward
                        move_vec.x, // left/right (strafe)
                        key_presses.jump,
                        key_presses.shift,
                        key_presses.sprint,
                    );

                    // Set player position for AI targeting (from ECS entity)
                    if (self.player_entity_id) |pid| {
                        if (ecs_world.getComponent(ecs.Transform, pid)) |t| {
                            ecs_world.setPlayerPosition(t.position);
                        }
                    }
                    ecs_world.tick();
                }
            }

            // AAA pattern: minimal main thread work
            // Heavy upload work (staging, allocations) is done by dedicated upload thread
            // tick() only processes ready uploads from upload thread (non-blocking)
            if (self.chunk_manager) |*cm| {
                cm.beginFrame();
                // C2ME-style: flush load queue once per frame, not per tick
                cm.flushLoadQueue();
                cm.tick(); // Now minimal: just applies ready uploads
            }

            const partial_tick: f32 = @floatCast(tick_accumulator / MS_PER_TICK);

            if (self.entity_renderer) |*er| {
                if (self.ecs_world) |*ecs_world| {
                    er.updateFromECS(ecs_world, partial_tick) catch |err| {
                        logger.err("Failed to update entity meshes: {}", .{err});
                    };
                }
            }

            // Position interpolated for smooth movement; rotation from ECS transform
            if (self.ecs_world) |*ecs_world| {
                if (self.player_entity_id) |pid| {
                    if (ecs_world.getComponent(ecs.Transform, pid)) |t| {
                        self.camera.position = t.getInterpolatedPosition(partial_tick);
                        self.camera.setRotation(t.getInterpolatedYaw(partial_tick), t.getInterpolatedPitch(partial_tick));
                    }
                }
            }

            if (self.entity_interaction) |*ei| {
                ei.updateTarget(&self.camera);
            }

            if (self.block_interaction) |*bi| {
                bi.updateHitResult(&self.camera);

                if (bi.hit_result) |hit| {
                    const block_entry = bi.chunk_manager.getBlockAt(
                        hit.block_pos.x,
                        hit.block_pos.y,
                        hit.block_pos.z,
                    ) orelse shared.BlockEntry.AIR;

                    const block_shape = block_entry.getShape();
                    _ = self.block_outline_renderer.generateOutline(hit.block_pos, block_shape);
                    self.block_outline_renderer.uploadToRenderSystem(&self.render_system) catch |err| {
                        logger.err("Failed to upload block outline: {}", .{err});
                    };
                } else {
                    self.block_outline_renderer.clear();
                    self.render_system.clearLineVertices();
                }
            }

            const aspect = self.render_system.getAspectRatio();
            const model = Mat4.IDENTITY;
            const view = self.camera.getViewMatrix();
            const proj = self.camera.getProjectionMatrix(aspect);

            self.render_system.updateMVP(model.data, view.data, proj.data);

            {
                const render_zone = profiler.traceNamed("RenderFrame");
                defer render_zone.end();

                if (self.use_async_chunks) {
                    if (self.chunk_manager) |*cm| {
                        const vertex_buffers = cm.getAllVertexBuffers();
                        const index_buffers = cm.getAllIndexBuffers();
                        const staging_copies = cm.getStagingCopies();

                        const entity_vb = if (self.entity_renderer) |*er| er.getVertexBuffer() else null;
                        const entity_ib = if (self.entity_renderer) |*er| er.getIndexBuffer() else null;
                        const adult_ic = if (self.entity_renderer) |*er| er.getAdultIndexCount() else 0;
                        const baby_ic = if (self.entity_renderer) |*er| er.getBabyIndexCount() else 0;

                        const chunk_count = cm.getActiveChunkCount();

                        if (vertex_buffers.len > 0 and index_buffers.len > 0 and chunk_count > 0) {
                            // Compute proj*view matrix for GPU frustum culling
                            // This transforms world space to clip space, required for frustum extraction
                            const view_proj = Mat4.multiply(proj, view);

                            self.render_system.drawFrameGPUDriven(
                                chunk_count,
                                view_proj.data,
                                vertex_buffers,
                                index_buffers,
                                staging_copies,
                                entity_vb,
                                entity_ib,
                                adult_ic,
                                baby_ic,
                            ) catch |err| {
                                logger.err("Failed to draw GPU-driven frame: {}", .{err});
                            };
                            cm.clearStagingCopies();
                        } else if (staging_copies.len > 0 and vertex_buffers.len > 0 and index_buffers.len > 0) {
                            // No chunks ready yet, just process staging copies
                            const view_proj = Mat4.multiply(proj, view);
                            self.render_system.drawFrameGPUDriven(
                                0,
                                view_proj.data,
                                vertex_buffers,
                                index_buffers,
                                staging_copies,
                                entity_vb,
                                entity_ib,
                                adult_ic,
                                baby_ic,
                            ) catch |err| {
                                logger.err("Failed to draw frame with staging: {}", .{err});
                            };
                            cm.clearStagingCopies();
                        } else {
                            self.render_system.drawFrame() catch |err| {
                                logger.err("Failed to draw frame: {}", .{err});
                            };
                        }
                    } else {
                        self.render_system.drawFrame() catch |err| {
                            logger.err("Failed to draw frame: {}", .{err});
                        };
                    }
                } else {
                    self.render_system.drawFrame() catch |err| {
                        logger.err("Failed to draw frame: {}", .{err});
                    };
                }
            }

            profiler.frameMark();
        }

        if (self.entity_renderer) |*er| {
            er.deinit();
        }
        if (self.ecs_world) |*ecs_world| {
            ecs_world.deinit();
        }
        if (self.entity_texture_manager) |*etm| {
            etm.deinit();
        }

        logger.info("Main loop ended, shutting down", .{});
    }

    /// Update hotbar icons with block textures
    fn updateHotbarIcons(self: *Self) !void {
        const tm = &(self.texture_manager orelse return error.TextureManagerNotInitialized);

        var texture_indices: [9]?[6]u32 = .{null} ** 9;

        for (0..9) |slot_idx| {
            const block_entry = self.hotbar.getSlot(@intCast(slot_idx));
            if (block_entry == null) continue;

            const entry = block_entry.?;
            if (entry.isAir()) continue;

            // Get texture indices for each face based on block ID
            // Face order: top(0), bottom(1), left/west(2), right/east(3), front/north(4), back/south(5)
            const block = entry.getBlock();
            const block_name = block.name;

            // Get base texture (for simple blocks, all faces use the same texture)
            const base_idx = tm.getTextureIndex(block_name);

            // Special handling for blocks with different face textures
            if (std.mem.eql(u8, block_name, "grass_block")) {
                texture_indices[slot_idx] = .{
                    tm.getTextureIndex("grass_block_top"),
                    tm.getTextureIndex("dirt"),
                    tm.getTextureIndex("grass_block_side"),
                    tm.getTextureIndex("grass_block_side"),
                    tm.getTextureIndex("grass_block_side"),
                    tm.getTextureIndex("grass_block_side"),
                };
            } else if (std.mem.eql(u8, block_name, "oak_log") or std.mem.eql(u8, block_name, "birch_log") or
                std.mem.eql(u8, block_name, "spruce_log") or std.mem.eql(u8, block_name, "jungle_log"))
            {
                // Log blocks have top/bottom bark texture, sides have log texture
                const log_top_name = std.fmt.allocPrint(self.allocator, "{s}_top", .{block_name}) catch {
                    texture_indices[slot_idx] = .{ base_idx, base_idx, base_idx, base_idx, base_idx, base_idx };
                    continue;
                };
                defer self.allocator.free(log_top_name);
                const top_idx = tm.getTextureIndex(log_top_name);
                texture_indices[slot_idx] = .{
                    top_idx,
                    top_idx,
                    base_idx,
                    base_idx,
                    base_idx,
                    base_idx,
                };
            } else if (std.mem.eql(u8, block_name, "crafting_table")) {
                texture_indices[slot_idx] = .{
                    tm.getTextureIndex("crafting_table_top"),
                    tm.getTextureIndex("oak_planks"),
                    tm.getTextureIndex("crafting_table_side"),
                    tm.getTextureIndex("crafting_table_front"),
                    tm.getTextureIndex("crafting_table_front"),
                    tm.getTextureIndex("crafting_table_side"),
                };
            } else {
                // Simple blocks - same texture on all faces
                texture_indices[slot_idx] = .{ base_idx, base_idx, base_idx, base_idx, base_idx, base_idx };
            }
        }

        try self.render_system.updateHotbarIcons(texture_indices);
    }

    fn testModelLoading(self: *Self) !void {
        logger.info("Loading and baking chunk...", .{});

        var model_loader = ModelLoader.init(self.allocator, self.io, self.config.location.asset_directory);
        defer model_loader.deinit();

        var blockstate_loader = BlockstateLoader.init(self.allocator, self.io, self.config.location.asset_directory);
        defer blockstate_loader.deinit();

        var block_model_shaper = BlockModelShaper.init(
            self.allocator,
            &model_loader,
            &blockstate_loader,
            &self.texture_manager.?,
        );
        defer block_model_shaper.deinit();

        const chunk = Chunk.generateTestChunk();

        // Count blocks to estimate buffer size
        var block_count: usize = 0;
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (!entry.isAir()) block_count += 1;
                }
            }
        }

        // Worst case: every block has all 6 faces visible
        const max_faces = block_count * 6;
        logger.info("Chunk has {d} blocks, allocating for up to {d} faces", .{ block_count, max_faces });

        const vertices = try self.allocator.alloc(Vertex, max_faces * 4);
        defer self.allocator.free(vertices);
        const indices = try self.allocator.alloc(u16, max_faces * 6);
        defer self.allocator.free(indices);

        var vertex_idx: usize = 0;
        var index_idx: usize = 0;

        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (entry.isAir()) continue;

                    const model = block_model_shaper.getModel(entry) catch |err| {
                        logger.warn("Failed to get model for block {}: {}", .{ entry.id, err });
                        continue;
                    };

                    const variant = block_model_shaper.getVariant(entry) catch |err| {
                        logger.warn("Failed to get variant for block {}: {}", .{ entry.id, err });
                        continue;
                    };

                    try bakeBlockAt(
                        model,
                        &chunk,
                        @intCast(x),
                        @intCast(y),
                        @intCast(z),
                        entry,
                        vertices,
                        indices,
                        &vertex_idx,
                        &index_idx,
                        &self.texture_manager.?,
                        variant.x,
                        variant.y,
                        variant.uvlock,
                    );
                }
            }
        }

        logger.info("Generated {d} vertices and {d} indices", .{ vertex_idx, index_idx });

        try self.render_system.uploadMesh(vertices[0..vertex_idx], indices[0..index_idx]);

        logger.info("Chunk baked and uploaded successfully!", .{});
    }

    /// Bake a block at chunk position with VoxelShape-based face culling
    fn bakeBlockAt(
        model: *const renderer.block.BlockModel,
        chunk: *const Chunk,
        x: i32,
        y: i32,
        z: i32,
        _: BlockEntry, // Previously used for whole-block culling, now unused with per-element culling
        vertices: []Vertex,
        indices: []u16,
        vertex_idx: *usize,
        index_idx: *usize,
        texture_manager: *const TextureManager,
        model_rotation_x: i16,
        model_rotation_y: i16,
        uvlock: bool,
    ) !void {
        const elements = model.elements orelse return error.NoElements;

        const color = [3]f32{ 1.0, 1.0, 1.0 };

        const directions = [_]Direction{ .down, .up, .north, .south, .west, .east };

        for (elements) |*elem| {
            for (directions) |dir| {
                if (elem.faces.get(dir)) |face| {
                    // Only cull faces with cullface specified; internal faces always render
                    if (face.cullface) |cullface_dir| {
                        const rotated_cullface = FaceBakery.rotateFaceDirection(cullface_dir, model_rotation_x, model_rotation_y);
                        const rotated_voxel_dir: VoxelDirection = @enumFromInt(@intFromEnum(rotated_cullface));
                        const rotated_bounds = FaceBakery.rotateElementBounds(
                            elem.from,
                            elem.to,
                            model_rotation_x,
                            model_rotation_y,
                        );

                        if (!chunk.shouldRenderElementFace(
                            x,
                            y,
                            z,
                            rotated_voxel_dir,
                            rotated_bounds.from,
                            rotated_bounds.to,
                            null,
                        )) {
                            continue;
                        }
                    }
                    // No cullface = internal face, always render

                    const texture_index = texture_manager.getTextureIndex(face.texture);

                    var quad = FaceBakery.bakeQuad(
                        elem.from,
                        elem.to,
                        face,
                        dir,
                        elem.rotation,
                        elem.shade,
                        elem.light_emission,
                        texture_index,
                    );

                    FaceBakery.rotateQuad(&quad, model_rotation_x, model_rotation_y, uvlock);

                    const offset_x: f32 = @floatFromInt(x);
                    const offset_y: f32 = @floatFromInt(y);
                    const offset_z: f32 = @floatFromInt(z);

                    const base_vertex: u16 = @intCast(vertex_idx.*);
                    for (0..4) |i| {
                        const pos = quad.position(@intCast(i));
                        const packed_uv = quad.packedUV(@intCast(i));
                        // UV packed as u64: u in high 32 bits, v in low 32 bits
                        const u: f32 = @bitCast(@as(u32, @intCast(packed_uv >> 32)));
                        const v: f32 = @bitCast(@as(u32, @intCast(packed_uv & 0xFFFFFFFF)));
                        vertices[vertex_idx.*] = .{
                            .pos = .{
                                pos[0] + offset_x,
                                pos[1] + offset_y,
                                pos[2] + offset_z,
                            },
                            .color = color,
                            .uv = .{ u, v },
                            .tex_index = quad.texture_index,
                        };
                        vertex_idx.* += 1;
                    }

                    // CCW winding
                    indices[index_idx.*] = base_vertex;
                    indices[index_idx.* + 1] = base_vertex + 1;
                    indices[index_idx.* + 2] = base_vertex + 2;
                    indices[index_idx.* + 3] = base_vertex + 2;
                    indices[index_idx.* + 4] = base_vertex + 3;
                    indices[index_idx.* + 5] = base_vertex;
                    index_idx.* += 6;
                }
            }
        }
    }
};
