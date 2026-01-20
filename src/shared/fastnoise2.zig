/// FastNoise2 Zig bindings
/// Provides access to SIMD-optimized noise generation functions
const std = @import("std");

const c = @cImport({
    @cInclude("stdbool.h");
    @cInclude("FastNoise/FastNoise_C.h");
});

/// SIMD feature level for noise generation
pub const SIMDLevel = enum(c_uint) {
    scalar = 0,
    sse = 1 << 0,
    sse2 = 1 << 1,
    sse3 = 1 << 2,
    ssse3 = 1 << 3,
    sse41 = 1 << 4,
    sse42 = 1 << 5,
    avx = 1 << 6,
    avx2 = 1 << 7,
    avx512 = 1 << 8,
    neon = 1 << 16,
    auto = 0xFFFFFFFF,
};

/// Min/max output values from noise generation
pub const OutputMinMax = struct {
    min: f32,
    max: f32,
};

/// FastNoise2 node handle
pub const Node = struct {
    handle: *anyopaque,

    const Self = @This();

    /// Create a node from an encoded node tree string (exported from NoiseTool)
    pub fn fromEncodedNodeTree(encoded_string: [*:0]const u8, simd_level: SIMDLevel) ?Self {
        const handle = c.fnNewFromEncodedNodeTree(encoded_string, @intFromEnum(simd_level));
        if (handle == null) return null;
        return Self{ .handle = handle.? };
    }

    /// Create a node from metadata ID
    /// Use getMetadataCount() and getMetadataName() to discover available types
    pub fn fromMetadata(id: i32, simd_level: SIMDLevel) ?Self {
        const handle = c.fnNewFromMetadata(id, @intFromEnum(simd_level));
        if (handle == null) return null;
        return Self{ .handle = handle.? };
    }

    /// Free the node
    pub fn deinit(self: Self) void {
        c.fnDeleteNodeRef(self.handle);
    }

    /// Get the SIMD level being used by this node
    pub fn getSIMDLevel(self: Self) SIMDLevel {
        return @enumFromInt(c.fnGetSIMDLevel(self.handle));
    }

    /// Get the metadata ID of this node
    pub fn getMetadataID(self: Self) i32 {
        return c.fnGetMetadataID(self.handle);
    }

    /// Generate a 2D grid of noise values
    /// This is the main SIMD-optimized batch generation function
    pub fn genUniformGrid2D(
        self: Self,
        noise_out: []f32,
        x_offset: f32,
        y_offset: f32,
        x_count: i32,
        y_count: i32,
        step_size: f32,
        seed: i32,
    ) OutputMinMax {
        var min_max: [2]f32 = undefined;
        c.fnGenUniformGrid2D(
            self.handle,
            noise_out.ptr,
            x_offset,
            y_offset,
            x_count,
            y_count,
            step_size,
            step_size,
            seed,
            &min_max,
        );
        return .{ .min = min_max[0], .max = min_max[1] };
    }

    /// Generate a 3D grid of noise values
    pub fn genUniformGrid3D(
        self: Self,
        noise_out: []f32,
        x_offset: f32,
        y_offset: f32,
        z_offset: f32,
        x_count: i32,
        y_count: i32,
        z_count: i32,
        step_size: f32,
        seed: i32,
    ) OutputMinMax {
        var min_max: [2]f32 = undefined;
        c.fnGenUniformGrid3D(
            self.handle,
            noise_out.ptr,
            x_offset,
            y_offset,
            z_offset,
            x_count,
            y_count,
            z_count,
            step_size,
            step_size,
            step_size,
            seed,
            &min_max,
        );
        return .{ .min = min_max[0], .max = min_max[1] };
    }

    /// Generate a single 2D noise value
    pub fn genSingle2D(self: Self, x: f32, y: f32, seed: i32) f32 {
        return c.fnGenSingle2D(self.handle, x, y, seed);
    }

    /// Generate a single 3D noise value
    pub fn genSingle3D(self: Self, x: f32, y: f32, z: f32, seed: i32) f32 {
        return c.fnGenSingle3D(self.handle, x, y, z, seed);
    }

    /// Set a float variable on this node
    pub fn setVariableFloat(self: Self, variable_index: i32, value: f32) bool {
        return c.fnSetVariableFloat(self.handle, variable_index, value);
    }

    /// Set an int/enum variable on this node
    pub fn setVariableIntEnum(self: Self, variable_index: i32, value: i32) bool {
        return c.fnSetVariableIntEnum(self.handle, variable_index, value);
    }

    /// Set a node lookup (source node) on this node
    pub fn setNodeLookup(self: Self, node_lookup_index: i32, source: Self) bool {
        return c.fnSetNodeLookup(self.handle, node_lookup_index, source.handle);
    }

    /// Set a hybrid node lookup
    pub fn setHybridNodeLookup(self: Self, hybrid_index: i32, source: Self) bool {
        return c.fnSetHybridNodeLookup(self.handle, hybrid_index, source.handle);
    }

    /// Set a hybrid float value
    pub fn setHybridFloat(self: Self, hybrid_index: i32, value: f32) bool {
        return c.fnSetHybridFloat(self.handle, hybrid_index, value);
    }
};

/// Get the number of available metadata types (noise generators)
pub fn getMetadataCount() i32 {
    return c.fnGetMetadataCount();
}

/// Get the name of a metadata type by ID
pub fn getMetadataName(id: i32) ?[*:0]const u8 {
    const name = c.fnGetMetadataName(id);
    if (name == null) return null;
    return name;
}

/// Get the number of variables for a metadata type
pub fn getMetadataVariableCount(id: i32) i32 {
    return c.fnGetMetadataVariableCount(id);
}

/// Get the name of a variable for a metadata type
pub fn getMetadataVariableName(id: i32, variable_index: i32) ?[*:0]const u8 {
    const name = c.fnGetMetadataVariableName(id, variable_index);
    if (name == null) return null;
    return name;
}

/// Get the number of node lookups for a metadata type
pub fn getMetadataNodeLookupCount(id: i32) i32 {
    return c.fnGetMetadataNodeLookupCount(id);
}

/// Get the name of a node lookup for a metadata type
pub fn getMetadataNodeLookupName(id: i32, node_lookup_index: i32) ?[*:0]const u8 {
    const name = c.fnGetMetadataNodeLookupName(id, node_lookup_index);
    if (name == null) return null;
    return name;
}
