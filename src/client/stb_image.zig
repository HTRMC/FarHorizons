const c = @cImport({
    @cInclude("stb_image.h");
});

pub const Image = struct {
    data: [*]u8,
    width: u32,
    height: u32,
    channels: u32,

    pub fn free(self: *Image) void {
        c.stbi_image_free(self.data);
        self.* = undefined;
    }
};

pub fn load(filename: [*:0]const u8, desired_channels: u32) !Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    const data = c.stbi_load(
        filename,
        &width,
        &height,
        &channels,
        @intCast(desired_channels),
    );

    if (data == null) {
        return error.ImageLoadFailed;
    }

    return Image{
        .data = data,
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = if (desired_channels != 0) desired_channels else @intCast(channels),
    };
}

pub fn loadFromMemory(buffer: []const u8, desired_channels: u32) !Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    const data = c.stbi_load_from_memory(
        buffer.ptr,
        @intCast(buffer.len),
        &width,
        &height,
        &channels,
        @intCast(desired_channels),
    );

    if (data == null) {
        return error.ImageLoadFailed;
    }

    return Image{
        .data = data,
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = if (desired_channels != 0) desired_channels else @intCast(channels),
    };
}

/// Set to flip images vertically on load (useful for OpenGL/Vulkan)
pub fn setFlipVerticallyOnLoad(flip: bool) void {
    c.stbi_set_flip_vertically_on_load(if (flip) 1 else 0);
}

/// Get the failure reason for the last failed load
pub fn failureReason() ?[*:0]const u8 {
    const reason = c.stbi_failure_reason();
    if (reason == null) return null;
    return reason;
}
