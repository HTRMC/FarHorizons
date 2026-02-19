pub const GpuVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    u: f32,
    v: f32,
    tex_index: u32,
    light: f32,
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
