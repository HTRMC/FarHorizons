pub const FaceData = extern struct {
    word0: u32,
    word1: u32,
};

/// Pack face data into two u32 words.
/// word0 bits [22:0] = x(5)|y(5)|z(5)|tex_index(8)
/// word0 bits [31:23] = model_index low 9 bits
/// word1 bits [7:0] = ao(2×4)
/// word1 bit 8 = flip
/// word1 bits [15:9] = model_index high 7 bits
pub fn packFaceData(x: u5, y: u5, z: u5, tex_index: u8, model_index: u16, ao: [4]u2) FaceData {
    const flip: u32 = @intFromBool(@as(u3, ao[0]) + ao[2] > @as(u3, ao[1]) + ao[3]);
    const mi: u32 = model_index;
    return .{
        .word0 = @as(u32, x) |
            (@as(u32, y) << 5) |
            (@as(u32, z) << 10) |
            (@as(u32, tex_index) << 15) |
            ((mi & 0x1FF) << 23),
        .word1 = @as(u32, ao[0]) |
            (@as(u32, ao[1]) << 2) |
            (@as(u32, ao[2]) << 4) |
            (@as(u32, ao[3]) << 6) |
            (flip << 8) |
            ((mi >> 9) << 9),
    };
}

pub const QuadModel = extern struct {
    corners: [12]f32,
    uvs: [8]f32,
    normal: [3]f32,
};

pub const LightEntry = extern struct {
    corners: [4]u32,
};

pub const ChunkData = extern struct {
    position: [3]i32,
    light_start: u32,
    face_start: u32,
    face_counts: [6]u32,
    voxel_size: u32,
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

pub const TextVertex = extern struct {
    px: f32,
    py: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    clip_min_x: f32 = -1e9,
    clip_min_y: f32 = -1e9,
    clip_max_x: f32 = 1e9,
    clip_max_y: f32 = 1e9,
};

pub const UiVertex = extern struct {
    px: f32,
    py: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    clip_min_x: f32 = -1e9,
    clip_min_y: f32 = -1e9,
    clip_max_x: f32 = 1e9,
    clip_max_y: f32 = 1e9,
    tex_index: f32 = -1.0,
};


fn unpackFaceData(fd: FaceData) struct { x: u5, y: u5, z: u5, tex_index: u8, model_index: u16 } {
    return .{
        .x = @intCast(fd.word0 & 0x1F),
        .y = @intCast((fd.word0 >> 5) & 0x1F),
        .z = @intCast((fd.word0 >> 10) & 0x1F),
        .tex_index = @intCast((fd.word0 >> 15) & 0xFF),
        .model_index = @intCast(((fd.word0 >> 23) & 0x1FF) | (((fd.word1 >> 9) & 0x7F) << 9)),
    };
}

fn unpackAo(fd: FaceData) [4]u2 {
    return .{
        @intCast(fd.word1 & 0x3),
        @intCast((fd.word1 >> 2) & 0x3),
        @intCast((fd.word1 >> 4) & 0x3),
        @intCast((fd.word1 >> 6) & 0x3),
    };
}

const no_ao = [4]u2{ 0, 0, 0, 0 };

test "packFaceData roundtrip - zero values" {
    const fd = packFaceData(0, 0, 0, 0, 0, no_ao);
    const u = unpackFaceData(fd);
    try std.testing.expectEqual(@as(u5, 0), u.x);
    try std.testing.expectEqual(@as(u5, 0), u.y);
    try std.testing.expectEqual(@as(u5, 0), u.z);
    try std.testing.expectEqual(@as(u8, 0), u.tex_index);
    try std.testing.expectEqual(@as(u16, 0), u.model_index);
    try std.testing.expectEqual(no_ao, unpackAo(fd));
}

test "packFaceData roundtrip - max values" {
    const fd = packFaceData(31, 31, 31, 255, 65535, .{ 3, 3, 3, 3 });
    const u = unpackFaceData(fd);
    try std.testing.expectEqual(@as(u5, 31), u.x);
    try std.testing.expectEqual(@as(u5, 31), u.y);
    try std.testing.expectEqual(@as(u5, 31), u.z);
    try std.testing.expectEqual(@as(u8, 255), u.tex_index);
    try std.testing.expectEqual(@as(u16, 65535), u.model_index);
    try std.testing.expectEqual([4]u2{ 3, 3, 3, 3 }, unpackAo(fd));
}

test "packFaceData roundtrip - typical values" {
    const fd = packFaceData(10, 20, 5, 3, 4, .{ 0, 1, 2, 3 });
    const u = unpackFaceData(fd);
    try std.testing.expectEqual(@as(u5, 10), u.x);
    try std.testing.expectEqual(@as(u5, 20), u.y);
    try std.testing.expectEqual(@as(u5, 5), u.z);
    try std.testing.expectEqual(@as(u8, 3), u.tex_index);
    try std.testing.expectEqual(@as(u16, 4), u.model_index);
    try std.testing.expectEqual([4]u2{ 0, 1, 2, 3 }, unpackAo(fd));
}

test "packFaceData - no field overlap" {
    const fd_x = packFaceData(31, 0, 0, 0, 0, no_ao);
    const u_x = unpackFaceData(fd_x);
    try std.testing.expectEqual(@as(u5, 31), u_x.x);
    try std.testing.expectEqual(@as(u5, 0), u_x.y);
    try std.testing.expectEqual(@as(u8, 0), u_x.tex_index);
    try std.testing.expectEqual(@as(u16, 0), u_x.model_index);

    const fd_t = packFaceData(0, 0, 0, 255, 0, no_ao);
    const u_t = unpackFaceData(fd_t);
    try std.testing.expectEqual(@as(u5, 0), u_t.x);
    try std.testing.expectEqual(@as(u5, 0), u_t.y);
    try std.testing.expectEqual(@as(u5, 0), u_t.z);
    try std.testing.expectEqual(@as(u8, 255), u_t.tex_index);
    try std.testing.expectEqual(@as(u16, 0), u_t.model_index);

    const fd_m = packFaceData(0, 0, 0, 0, 65535, no_ao);
    const u_m = unpackFaceData(fd_m);
    try std.testing.expectEqual(@as(u5, 0), u_m.x);
    try std.testing.expectEqual(@as(u8, 0), u_m.tex_index);
    try std.testing.expectEqual(@as(u16, 65535), u_m.model_index);

    const fd_ao = packFaceData(0, 0, 0, 0, 0, .{ 1, 2, 3, 0 });
    const u_ao = unpackFaceData(fd_ao);
    try std.testing.expectEqual(@as(u5, 0), u_ao.x);
    try std.testing.expectEqual(@as(u8, 0), u_ao.tex_index);
    try std.testing.expectEqual([4]u2{ 1, 2, 3, 0 }, unpackAo(fd_ao));
}

test "packFaceData - shader unpacking matches" {
    // Use model_index 34981: low 9 bits = 165, high 7 bits = 68
    const fd = packFaceData(15, 8, 22, 130, 34981, .{ 2, 1, 3, 0 });
    const w = fd.word0;
    try std.testing.expectEqual(@as(u32, 15), w & 0x1F);
    try std.testing.expectEqual(@as(u32, 8), (w >> 5) & 0x1F);
    try std.testing.expectEqual(@as(u32, 22), (w >> 10) & 0x1F);
    try std.testing.expectEqual(@as(u32, 130), (w >> 15) & 0xFF);
    try std.testing.expectEqual(@as(u32, 165), (w >> 23) & 0x1FF); // low 9 bits
    const w1 = fd.word1;
    try std.testing.expectEqual(@as(u32, 2), w1 & 0x3);
    try std.testing.expectEqual(@as(u32, 1), (w1 >> 2) & 0x3);
    try std.testing.expectEqual(@as(u32, 3), (w1 >> 4) & 0x3);
    try std.testing.expectEqual(@as(u32, 0), (w1 >> 6) & 0x3);
    try std.testing.expectEqual(@as(u32, 1), (w1 >> 8) & 0x1);
    try std.testing.expectEqual(@as(u32, 68), (w1 >> 9) & 0x7F); // high 7 bits
    // Verify full model_index roundtrip
    const u = unpackFaceData(fd);
    try std.testing.expectEqual(@as(u16, 34981), u.model_index);
}

test "packFaceData - flip bit set only when needed" {
    const fd_sym = packFaceData(0, 0, 0, 0, 0, .{ 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u32, 0), (fd_sym.word1 >> 8) & 0x1);

    const fd_flip = packFaceData(0, 0, 0, 0, 0, .{ 3, 0, 3, 0 });
    try std.testing.expectEqual(@as(u32, 1), (fd_flip.word1 >> 8) & 0x1);

    const fd_nf = packFaceData(0, 0, 0, 0, 0, .{ 0, 3, 0, 3 });
    try std.testing.expectEqual(@as(u32, 0), (fd_nf.word1 >> 8) & 0x1);

    const fd_eq = packFaceData(0, 0, 0, 0, 0, .{ 1, 2, 2, 1 });
    try std.testing.expectEqual(@as(u32, 0), (fd_eq.word1 >> 8) & 0x1);
}

const std = @import("std");
