// FarHorizons Client - main client orchestration

const std = @import("std");
const shared = @import("shared");
const platform = @import("platform");
const renderer = @import("renderer");
const client_player = @import("player/player.zig");

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;
const Camera = shared.Camera;
const Mat4 = shared.Mat4;
const Vec3 = shared.Vec3;
const Window = platform.Window;
const DisplayData = platform.DisplayData;
const MouseHandler = platform.MouseHandler;
const KeyboardInput = platform.KeyboardInput;
const InputConstants = platform.InputConstants;
const RenderSystem = renderer.RenderSystem;
const Vertex = renderer.Vertex;
const ModelLoader = renderer.block.ModelLoader;
const FaceBakery = renderer.block.FaceBakery;
const BakedQuad = renderer.block.BakedQuad;
const Direction = renderer.block.Direction;
const LocalPlayer = client_player.LocalPlayer;

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
        camera.position = .{ .x = 0, .y = 0, .z = 3 };

        return Self{
            .config = config,
            .window = Window.init(display_data),
            .mouse_handler = undefined, // Initialized in run() after struct is at final location
            .keyboard_input = undefined, // Initialized in run() after struct is at final location
            .render_system = RenderSystem.init(allocator),
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
        self.local_player.setPosition(Vec3{ .x = 0, .y = 0, .z = 3 });

        // Initialize render system (Vulkan) with window for surface
        try self.render_system.initBackend(&self.window);
        defer self.render_system.shutdown();

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
        logger.info("Loading and baking model...", .{});

        var model_loader = ModelLoader.init(self.allocator, self.config.location.asset_directory);
        defer model_loader.deinit();

        // Load oak_slab which has parent chain: oak_slab -> slab -> block
        var model = model_loader.loadModel("farhorizons:block/oak_slab") catch |err| {
            logger.err("Failed to load oak_slab model: {}", .{err});
            return err;
        };
        defer model.deinit();

        // Resolve texture references
        model_loader.resolveTextures(&model) catch |err| {
            logger.err("Failed to resolve textures: {}", .{err});
            return err;
        };

        // Bake the model into quads
        const elements = model.elements orelse {
            logger.err("Model has no elements", .{});
            return error.NoElements;
        };

        // Count total faces to allocate arrays
        var total_faces: usize = 0;
        for (elements) |*elem| {
            inline for (std.meta.fields(Direction)) |field| {
                const dir: Direction = @enumFromInt(field.value);
                if (elem.faces.get(dir) != null) {
                    total_faces += 1;
                }
            }
        }

        logger.info("Baking {d} faces from {d} elements", .{ total_faces, elements.len });

        // Allocate arrays for vertices and indices
        // Each quad has 4 vertices and 6 indices (2 triangles)
        const vertices = try self.allocator.alloc(Vertex, total_faces * 4);
        defer self.allocator.free(vertices);
        const indices = try self.allocator.alloc(u16, total_faces * 6);
        defer self.allocator.free(indices);

        // Colors for each face direction (for debugging without textures)
        const FACE_COLORS = struct {
            fn get(dir: Direction) [3]f32 {
                return switch (dir) {
                    .down => .{ 1.0, 0.0, 1.0 }, // magenta
                    .up => .{ 0.0, 1.0, 1.0 }, // cyan
                    .north => .{ 0.0, 1.0, 0.0 }, // green
                    .south => .{ 1.0, 0.0, 0.0 }, // red
                    .west => .{ 1.0, 1.0, 0.0 }, // yellow
                    .east => .{ 0.0, 0.0, 1.0 }, // blue
                };
            }
        };

        var vertex_idx: usize = 0;
        var index_idx: usize = 0;

        for (elements) |*elem| {
            inline for (std.meta.fields(Direction)) |field| {
                const dir: Direction = @enumFromInt(field.value);
                if (elem.faces.get(dir)) |face| {
                    // Bake the face into a quad
                    const quad = FaceBakery.bakeQuad(
                        elem.from,
                        elem.to,
                        face,
                        dir,
                        elem.rotation,
                        elem.shade,
                        elem.light_emission,
                    );

                    // Get color for this direction
                    const color = FACE_COLORS.get(dir);

                    // Add vertices (offset to center the model)
                    const base_vertex: u16 = @intCast(vertex_idx);
                    for (0..4) |i| {
                        const pos = quad.position(@intCast(i));
                        vertices[vertex_idx] = .{
                            .pos = .{ pos[0] - 0.5, pos[1] - 0.5, pos[2] - 0.5 },
                            .color = color,
                        };
                        vertex_idx += 1;
                    }

                    // Add indices for two triangles (CCW winding)
                    indices[index_idx] = base_vertex;
                    indices[index_idx + 1] = base_vertex + 1;
                    indices[index_idx + 2] = base_vertex + 2;
                    indices[index_idx + 3] = base_vertex + 2;
                    indices[index_idx + 4] = base_vertex + 3;
                    indices[index_idx + 5] = base_vertex;
                    index_idx += 6;
                }
            }
        }

        logger.info("Generated {d} vertices and {d} indices", .{ vertex_idx, index_idx });

        // Upload mesh to render system
        try self.render_system.uploadMesh(vertices[0..vertex_idx], indices[0..index_idx]);

        logger.info("Model baked and uploaded successfully!", .{});
    }
};
