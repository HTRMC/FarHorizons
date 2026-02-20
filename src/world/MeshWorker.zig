const std = @import("std");
const WorldState = @import("WorldState.zig");
const types = @import("../renderer/vulkan/types.zig");
const GpuVertex = types.GpuVertex;
const DrawCommand = types.DrawCommand;
const tracy = @import("../platform/tracy.zig");

pub const MeshWorker = struct {
    state: std.atomic.Value(State),
    vertices: ?[]GpuVertex,
    indices: ?[]u32,
    vertex_count: u32,
    index_count: u32,
    chunk_positions: ?[][4]f32,
    draw_commands: ?[]DrawCommand,
    draw_count: u32,
    thread: ?std.Thread,
    allocator: std.mem.Allocator,
    world: *const WorldState.World,

    pub const State = enum(u8) { idle, working, ready };

    pub const MeshResult = struct {
        vertices: []GpuVertex,
        indices: []u32,
        vertex_count: u32,
        index_count: u32,
        chunk_positions: [][4]f32,
        draw_commands: []DrawCommand,
        draw_count: u32,
    };

    pub fn init(allocator: std.mem.Allocator, world: *const WorldState.World) MeshWorker {
        return .{
            .state = std.atomic.Value(State).init(.idle),
            .vertices = null,
            .indices = null,
            .vertex_count = 0,
            .index_count = 0,
            .chunk_positions = null,
            .draw_commands = null,
            .draw_count = 0,
            .thread = null,
            .allocator = allocator,
            .world = world,
        };
    }

    pub fn start(self: *MeshWorker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.state.store(.working, .release);
        self.thread = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn mesh worker thread: {}", .{err});
            self.state.store(.idle, .release);
            return;
        };
    }

    pub fn poll(self: *MeshWorker) ?MeshResult {
        if (self.state.load(.acquire) != .ready) return null;

        const result = MeshResult{
            .vertices = self.vertices.?,
            .indices = self.indices.?,
            .vertex_count = self.vertex_count,
            .index_count = self.index_count,
            .chunk_positions = self.chunk_positions.?,
            .draw_commands = self.draw_commands.?,
            .draw_count = self.draw_count,
        };

        self.vertices = null;
        self.indices = null;
        self.chunk_positions = null;
        self.draw_commands = null;
        self.state.store(.idle, .release);

        return result;
    }

    pub fn deinit(self: *MeshWorker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.vertices) |v| self.allocator.free(v);
        if (self.indices) |i| self.allocator.free(i);
        if (self.chunk_positions) |cp| self.allocator.free(cp);
        if (self.draw_commands) |dc| self.allocator.free(dc);
    }

    fn workerFn(self: *MeshWorker) void {
        const tz = tracy.zone(@src(), "MeshWorker.workerFn");
        defer tz.end();

        const mesh = WorldState.generateWorldMesh(self.allocator, self.world) catch |err| {
            std.log.err("Mesh generation failed: {}", .{err});
            self.state.store(.idle, .release);
            return;
        };

        self.vertices = mesh.vertices;
        self.indices = mesh.indices;
        self.vertex_count = mesh.vertex_count;
        self.index_count = mesh.index_count;
        self.chunk_positions = mesh.chunk_positions;
        self.draw_commands = mesh.draw_commands;
        self.draw_count = mesh.draw_count;
        self.state.store(.ready, .release);
    }
};
