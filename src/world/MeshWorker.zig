const std = @import("std");
const WorldState = @import("WorldState.zig");
const GpuVertex = @import("../renderer/vulkan/types.zig").GpuVertex;
const tracy = @import("../platform/tracy.zig");

pub const MeshWorker = struct {
    state: std.atomic.Value(State),
    vertices: ?[]GpuVertex,
    indices: ?[]u32,
    vertex_count: u32,
    index_count: u32,
    thread: ?std.Thread,
    allocator: std.mem.Allocator,

    pub const State = enum(u8) { idle, working, ready };

    pub const MeshResult = struct {
        vertices: []GpuVertex,
        indices: []u32,
        vertex_count: u32,
        index_count: u32,
    };

    pub fn init(allocator: std.mem.Allocator) MeshWorker {
        return .{
            .state = std.atomic.Value(State).init(.idle),
            .vertices = null,
            .indices = null,
            .vertex_count = 0,
            .index_count = 0,
            .thread = null,
            .allocator = allocator,
        };
    }

    pub fn start(self: *MeshWorker) void {
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
        };

        self.vertices = null;
        self.indices = null;
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
    }

    fn workerFn(self: *MeshWorker) void {
        const tz = tracy.zone(@src(), "MeshWorker.workerFn");
        defer tz.end();

        const world = comptime WorldState.generateSphereWorld();
        const mesh = WorldState.generateWorldMesh(self.allocator, &world) catch |err| {
            std.log.err("Mesh generation failed: {}", .{err});
            self.state.store(.idle, .release);
            return;
        };

        self.vertices = mesh.vertices;
        self.indices = mesh.indices;
        self.vertex_count = mesh.vertex_count;
        self.index_count = mesh.index_count;
        self.state.store(.ready, .release);
    }
};
