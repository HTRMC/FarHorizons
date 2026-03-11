const c = @import("c.zig").c;

pub fn load(filename: [*:0]const u8, x: *c_int, y: *c_int, channels: *c_int, desired_channels: c_int) ?[*]u8 {
    return c.stbi_load(filename, x, y, channels, desired_channels);
}

pub fn free(data: *anyopaque) void {
    c.stbi_image_free(data);
}
