// FarHorizons Client - main client orchestration

const std = @import("std");
const shared = @import("Shared");
const platform = @import("Platform");
const renderer = @import("Renderer");
const client_player = @import("player/Player.zig");

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
const ModelLoader = renderer.block.ModelLoader;
const FaceBakery = renderer.block.FaceBakery;
const BakedQuad = renderer.block.BakedQuad;
const Direction = renderer.block.Direction;
const BlockstateLoader = renderer.block.BlockstateLoader;
const BlockModelShaper = renderer.block.BlockModelShaper;
const LocalPlayer = client_player.LocalPlayer;

// VoxelShape culling
const VoxelDirection = shared.Direction;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    // Minecraft runs at 20 ticks per second (50ms per tick)
    const TICK_RATE: f64 = 20.0;
    const MS_PER_TICK: f64 = 1000.0 / TICK_RATE; // 50ms

    config: GameConfig,
    window: Window,
    mouse_handler: MouseHandler,
    keyboard_input: KeyboardInput,
    render_system: RenderSystem,
    texture_manager: ?TextureManager,
    camera: Camera,
    local_player: LocalPlayer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: GameConfig) Self {
        const display_data = DisplayData{
            .width = @intCast(config.display.width),
            .height = @intCast(config.display.height),
            .fullscreen = config.display.fullscreen,
        };

        // Initialize camera for rendering
        var camera = Camera.init();
        camera.position = .{ .x = 8, .y = 10, .z = 20 }; // Above and behind chunk center
        camera.setRotation(180, 0); // Face towards -Z (towards the chunk)

        return Self{
            .config = config,
            .window = Window.init(display_data),
            .mouse_handler = undefined, // Initialized in run() after struct is at final location
            .keyboard_input = undefined, // Initialized in run() after struct is at final location
            .render_system = RenderSystem.init(allocator),
            .texture_manager = null, // Initialized in run() after render_system
            .camera = camera,
            .local_player = undefined, // Initialized in run() after keyboard_input is ready
            .allocator = allocator,
        };
    }

    pub fn run(self: *Self) !void {
        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});

        // Initialize platform backend (GLFW)
        try platform.initBackend();
        defer platform.terminateBackend();

        // Create window first (needed for surface creation)
        try self.window.create("FarHorizons");
        defer self.window.destroy();

        // Initialize input handlers (must be done here after struct is at final location)
        self.mouse_handler = MouseHandler.init(&self.window);
        self.mouse_handler.setup();
        self.keyboard_input = KeyboardInput.init(&self.window);

        // Initialize local player with keyboard input
        self.local_player = LocalPlayer.init(&self.keyboard_input);
        self.local_player.setPosition(Vec3{ .x = 8, .y = 10, .z = 20 }); // Above and behind chunk center
        self.local_player.setYRot(180); // Face towards -Z (towards the chunk)

        // Initialize render system (Vulkan) with window for surface
        try self.render_system.initBackend(&self.window);
        defer self.render_system.shutdown();

        // Initialize texture manager and load block textures
        self.texture_manager = TextureManager.init(
            self.allocator,
            self.config.location.asset_directory,
            self.render_system.getDevice(),
            self.render_system.getPhysicalDevice(),
            self.render_system.getCommandPool(),
            self.render_system.getGraphicsQueue(),
        );
        try self.texture_manager.?.loadBlockTextures();
        defer self.texture_manager.?.deinit();

        // Set texture resources to render system and create descriptors
        try self.render_system.setTextureResources(
            self.texture_manager.?.getImageView(),
            self.texture_manager.?.getSampler(),
        );

        // Test model loading
        try self.testModelLoading();

        // Render first frame before showing window (avoids white flash)
        self.render_system.drawFrame() catch {};
        self.window.show();

        // Track ESC key state for edge detection
        var esc_was_pressed = false;

        // Tick timing (like Minecraft's 20 ticks/second)
        var timer = std.time.Timer.start() catch {
            logger.err("Failed to start timer", .{});
            return;
        };
        var tick_accumulator: f64 = 0;

        // Main loop
        logger.info("Entering main loop", .{});
        while (!self.window.shouldClose()) {
            // Calculate delta time for tick accumulator
            const delta_ns = timer.lap();
            const delta_ms: f64 = @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
            tick_accumulator += delta_ms;

            platform.pollEvents();

            // Check for escape key (edge detection - only trigger on press, not hold)
            const esc_pressed = self.window.isKeyPressed(InputConstants.KEY_ESCAPE);
            if (esc_pressed and !esc_was_pressed) {
                if (self.mouse_handler.isMouseGrabbed()) {
                    // Release mouse when ESC is pressed (like Minecraft pause menu)
                    self.mouse_handler.releaseMouse();
                } else {
                    // Close window if mouse is already released
                    self.window.setShouldClose(true);
                }
            }
            esc_was_pressed = esc_pressed;

            // Handle mouse movement for camera rotation (when grabbed)
            // Mouse look is frame-rate independent, not tied to ticks
            if (self.mouse_handler.isMouseGrabbed()) {
                const rotation = self.mouse_handler.getCameraRotation();
                self.local_player.setYRot(self.local_player.getYRot() + @as(f32, @floatCast(rotation.yaw)));
                self.local_player.setXRot(self.local_player.getXRot() + @as(f32, @floatCast(rotation.pitch)));

                // Handle scroll wheel for flying speed (like Minecraft spectator mode)
                const scroll = self.mouse_handler.getAccumulatedScroll();
                if (scroll != 0) {
                    self.local_player.getAbilities().adjustFlyingSpeed(@floatCast(scroll));
                }
            }

            // Run game ticks at fixed rate (20 ticks/second like Minecraft)
            while (tick_accumulator >= MS_PER_TICK) {
                tick_accumulator -= MS_PER_TICK;

                // Save old position before tick (for interpolation)
                self.local_player.setOldPosAndRot();

                // Update keyboard input
                self.keyboard_input.tick();

                // Update player movement
                self.local_player.aiStep();
            }

            // Calculate partial tick for interpolation (0.0 to 1.0)
            const partial_tick: f32 = @floatCast(tick_accumulator / MS_PER_TICK);

            // Sync camera with interpolated player position for smooth rendering
            // Position is interpolated between ticks for smooth movement
            // Rotation is NOT interpolated - mouse look must be instant
            self.camera.position = self.local_player.getPosition(partial_tick);
            self.camera.setRotation(self.local_player.getYRot(), self.local_player.getXRot());

            // Update MVP matrices
            const aspect = self.render_system.getAspectRatio();
            const model = Mat4.IDENTITY;
            const view = self.camera.getViewMatrix();
            const proj = self.camera.getProjectionMatrix(aspect);

            self.render_system.updateMVP(model.data, view.data, proj.data);

            // Render frame
            self.render_system.drawFrame() catch |err| {
                logger.err("Failed to draw frame: {}", .{err});
            };
        }

        logger.info("Main loop ended, shutting down", .{});
    }

    fn testModelLoading(self: *Self) !void {
        logger.info("Loading and baking chunk...", .{});

        // Initialize model loading system
        var model_loader = ModelLoader.init(self.allocator, self.config.location.asset_directory);
        defer model_loader.deinit();

        var blockstate_loader = BlockstateLoader.init(self.allocator, self.config.location.asset_directory);
        defer blockstate_loader.deinit();

        var block_model_shaper = BlockModelShaper.init(
            self.allocator,
            &model_loader,
            &blockstate_loader,
            &self.texture_manager.?,
        );
        defer block_model_shaper.deinit();

        // Generate a test chunk
        const chunk = Chunk.generateTestChunk();

        // Count blocks in chunk to estimate buffer size
        var block_count: usize = 0;
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (!entry.isAir()) block_count += 1;
                }
            }
        }

        // Worst case: every block has all faces visible
        const max_faces = block_count * 6;
        logger.info("Chunk has {d} blocks, allocating for up to {d} faces", .{ block_count, max_faces });

        // Allocate arrays for vertices and indices
        const vertices = try self.allocator.alloc(Vertex, max_faces * 4);
        defer self.allocator.free(vertices);
        const indices = try self.allocator.alloc(u16, max_faces * 6);
        defer self.allocator.free(indices);

        var vertex_idx: usize = 0;
        var index_idx: usize = 0;

        // Iterate through chunk and bake visible faces
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (entry.isAir()) continue;

                    // Get the model for this block via blockstate system
                    const model = block_model_shaper.getModel(entry) catch |err| {
                        logger.warn("Failed to get model for block {}: {}", .{ entry.id, err });
                        continue;
                    };

                    // Get variant for rotation info
                    const variant = block_model_shaper.getVariant(entry) catch |err| {
                        logger.warn("Failed to get variant for block {}: {}", .{ entry.id, err });
                        continue;
                    };

                    // Bake with face culling and model rotation
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

        // Upload mesh to render system
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
        entry: BlockEntry,
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

        // White color (texture provides color)
        const color = [3]f32{ 1.0, 1.0, 1.0 };

        const directions = [_]Direction{ .down, .up, .north, .south, .west, .east };

        for (elements) |*elem| {
            for (directions) |dir| {
                if (elem.faces.get(dir)) |face| {
                    // Transform face direction by model rotation for correct culling
                    // When a model is rotated, its faces point in different directions
                    const rotated_render_dir = FaceBakery.rotateFaceDirection(dir, model_rotation_x, model_rotation_y);

                    // Convert to VoxelDirection for culling (same enum values)
                    const rotated_voxel_dir: VoxelDirection = @enumFromInt(@intFromEnum(rotated_render_dir));

                    // Use VoxelShape-based culling with the ROTATED direction
                    if (!chunk.shouldRenderFaceVoxelEntry(x, y, z, rotated_voxel_dir, entry, null)) {
                        continue; // Skip this face - occluded by neighbor's shape
                    }

                    // Get texture index from texture name
                    const texture_index = texture_manager.getTextureIndex(face.texture) orelse 0;

                    // Bake the face into a quad
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

                    // Apply model-level rotation from blockstate variant
                    FaceBakery.rotateQuad(&quad, model_rotation_x, model_rotation_y, uvlock);

                    // World position offset (chunk coords to world coords)
                    const offset_x: f32 = @floatFromInt(x);
                    const offset_y: f32 = @floatFromInt(y);
                    const offset_z: f32 = @floatFromInt(z);

                    // Add vertices with position offset and UVs
                    const base_vertex: u16 = @intCast(vertex_idx.*);
                    for (0..4) |i| {
                        const pos = quad.position(@intCast(i));
                        const packed_uv = quad.packedUV(@intCast(i));
                        // Unpack UV from u64 (u in high 32 bits, v in low 32 bits)
                        const u: f32 = @bitCast(@as(u32, @intCast(packed_uv >> 32)));
                        const v: f32 = @bitCast(@as(u32, @intCast(packed_uv & 0xFFFFFFFF)));
                        // Normalize UVs from 0-16 Minecraft coords to 0-1
                        vertices[vertex_idx.*] = .{
                            .pos = .{
                                pos[0] - 0.5 + offset_x,
                                pos[1] - 0.5 + offset_y,
                                pos[2] - 0.5 + offset_z,
                            },
                            .color = color,
                            .uv = .{ u / 16.0, v / 16.0 },
                            .tex_index = quad.texture_index,
                        };
                        vertex_idx.* += 1;
                    }

                    // Add indices for two triangles (CCW winding)
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
