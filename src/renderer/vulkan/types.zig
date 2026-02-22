pub const FaceData = extern struct {
    word0: u32, // x:5 | y:5 | z:5 | texIndex:8 | normalIndex:3 | lightIndex:6
    word1: u32, // reserved
};

pub fn packFaceData(x: u5, y: u5, z: u5, tex_index: u8, normal_index: u3, light_index: u6) FaceData {
    return .{
        .word0 = @as(u32, x) |
            (@as(u32, y) << 5) |
            (@as(u32, z) << 10) |
            (@as(u32, tex_index) << 15) |
            (@as(u32, normal_index) << 23) |
            (@as(u32, light_index) << 26),
        .word1 = 0,
    };
}

pub const QuadModel = extern struct {
    corners: [12]f32, // 4 corners x 3 components (px,py,pz)
    uvs: [8]f32, // 4 corners x 2 components (u,v)
    normal: [3]f32, // face normal
};

pub const LightEntry = extern struct {
    corners: [4]u32, // packed R8G8B8 per corner
};

pub const ChunkData = extern struct {
    position: [3]i32, // world-space chunk origin in blocks
    light_start: u32, // offset into global light buffer
    face_start: u32, // offset into global face buffer
    face_counts: [6]u32, // per-normal face count (+Z,-Z,-X,+X,+Y,-Y)
};

pub const DrawCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const LineVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};
