const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");
const platform = @import("Platform");
const renderer = @import("Renderer");
const world = @import("World");
const ecs = @import("ecs");
const client_player = @import("player/Player.zig");
const block_interaction = @import("BlockInteraction.zig");
const BlockInteraction = block_interaction.BlockInteraction;
const entity_interaction = @import("EntityInteraction.zig");
const EntityInteraction = entity_interaction.EntityInteraction;
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
const LocalPlayer = client_player.LocalPlayer;
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
    local_player: LocalPlayer,
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
            .local_player = undefined, // Initialized in run() after keyboard_input is ready
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

        self.local_player = LocalPlayer.init(&self.keyboard_input);
        self.local_player.setPosition(Vec3{ .x = 8, .y = 100, .z = 20 }); // Above terrain (base height 64 + variation)
        self.local_player.setYRot(180); // Face towards -Z (towards the chunk)

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

        if (self.use_async_chunks) {
            self.chunk_manager = try ChunkManager.init(
                self.allocator,
                self.io,
                &self.render_system,
                &self.texture_manager.?,
                self.config.location.asset_directory,
                ChunkConfig{
                    .view_distance = 16,
                    .vertical_view_distance = 4,
                    .unload_distance = 18,
                    .worker_count = 4,
                    .max_uploads_per_tick = 64,
                },
            );
            try self.chunk_manager.?.start();
            self.chunk_manager.?.updatePlayerPosition(self.local_player.getPosition(0));
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
                self.local_player.setYRot(self.local_player.getYRot() + @as(f32, @floatCast(rotation.yaw)));
                self.local_player.setXRot(self.local_player.getXRot() + @as(f32, @floatCast(rotation.pitch)));

                const scroll = self.mouse_handler.getAccumulatedScroll();
                if (scroll != 0) {
                    if (self.window.isKeyPressed(InputConstants.KEY_LEFT_SHIFT)) {
                        self.local_player.getAbilities().adjustFlyingSpeed(@floatCast(scroll));
                    } else if (self.block_interaction) |*bi| {
                        bi.cycleSelectedBlock(scroll > 0);
                    }
                }
            }

            while (tick_accumulator >= MS_PER_TICK) {
                const tick_zone = profiler.traceNamed("GameTick");
                defer tick_zone.end();

                tick_accumulator -= MS_PER_TICK;

                // For interpolation
                self.local_player.setOldPosAndRot();

                self.keyboard_input.tick();
                self.local_player.aiStep();

                if (self.chunk_manager) |*cm| {
                    cm.updatePlayerPosition(self.local_player.getPosition(0));
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
                            attacked_entity = ei.handleAttack(self.local_player.getPosition(0));
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

                    ecs_world.setPlayerPosition(self.local_player.getPosition(0));
                    ecs_world.tick();
                }
            }

            // Main thread only: process completed chunk meshes
            if (self.chunk_manager) |*cm| {
                cm.beginFrame(self.render_system.getCurrentFrameFence());
                // C2ME-style: flush load queue once per frame, not per tick
                cm.flushLoadQueue();
                cm.tick();
            }

            const partial_tick: f32 = @floatCast(tick_accumulator / MS_PER_TICK);

            if (self.entity_renderer) |*er| {
                if (self.ecs_world) |*ecs_world| {
                    er.updateFromECS(ecs_world, partial_tick) catch |err| {
                        logger.err("Failed to update entity meshes: {}", .{err});
                    };
                }
            }

            // Position interpolated for smooth movement; rotation NOT interpolated (instant mouse look)
            self.camera.position = self.local_player.getPosition(partial_tick);
            self.camera.setRotation(self.local_player.getYRot(), self.local_player.getXRot());

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
                        const draw_commands = cm.getDrawCommands();
                        const staging_copies = cm.getStagingCopies();

                        const entity_vb = if (self.entity_renderer) |*er| er.getVertexBuffer() else null;
                        const entity_ib = if (self.entity_renderer) |*er| er.getIndexBuffer() else null;
                        const entity_ic = if (self.entity_renderer) |*er| er.getIndexCount() else 0;
                        const adult_ic = if (self.entity_renderer) |*er| er.getAdultIndexCount() else 0;
                        const baby_is = if (self.entity_renderer) |*er| er.getBabyIndexStart() else 0;
                        const baby_ic = if (self.entity_renderer) |*er| er.getBabyIndexCount() else 0;

                        if (vertex_buffers.len > 0 and index_buffers.len > 0 and draw_commands.len > 0) {
                            self.render_system.drawFrameMultiArena(
                                vertex_buffers,
                                index_buffers,
                                draw_commands,
                                staging_copies,
                                entity_vb,
                                entity_ib,
                                entity_ic,
                                adult_ic,
                                baby_is,
                                baby_ic,
                            ) catch |err| {
                                logger.err("Failed to draw multi-arena frame: {}", .{err});
                            };
                            // Clear staging copies after they've been submitted
                            cm.clearStagingCopies();
                        } else if (staging_copies.len > 0 and vertex_buffers.len > 0 and index_buffers.len > 0) {
                            self.render_system.drawFrameMultiArena(
                                vertex_buffers,
                                index_buffers,
                                &.{},
                                staging_copies,
                                entity_vb,
                                entity_ib,
                                entity_ic,
                                adult_ic,
                                baby_is,
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
