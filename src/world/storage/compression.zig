const std = @import("std");
const storage_types = @import("types.zig");
const build_options = @import("build_options");

const CompressionAlgo = storage_types.CompressionAlgo;


pub const zstd_enabled = build_options.zstd_enabled;

const zstd = if (zstd_enabled) @cImport(@cInclude("zstd.h")) else struct {};


pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    UnsupportedAlgorithm,
    OutputTooSmall,
    OutOfMemory,
};

pub fn compress(
    algo: CompressionAlgo,
    input: []const u8,
    output: []u8,
) CompressionError!usize {
    return switch (algo) {
        .none => compressNone(input, output),
        .deflate => compressDeflate(input, output),
        .zstd => compressZstd(input, output),
    };
}

pub fn decompress(
    algo: CompressionAlgo,
    input: []const u8,
    output: []u8,
    expected_size: usize,
) CompressionError!usize {
    return switch (algo) {
        .none => decompressNone(input, output, expected_size),
        .deflate => decompressDeflate(input, output),
        .zstd => decompressZstd(input, output, expected_size),
    };
}

pub fn compressBound(algo: CompressionAlgo, input_size: usize) usize {
    return switch (algo) {
        .none => input_size,
        .deflate => input_size + input_size / 7 + 64,
        .zstd => if (zstd_enabled)
            zstd.ZSTD_compressBound(input_size)
        else
            input_size + input_size / 4 + 64,
    };
}


fn compressNone(input: []const u8, output: []u8) CompressionError!usize {
    if (output.len < input.len) return error.OutputTooSmall;
    @memcpy(output[0..input.len], input);
    return input.len;
}

fn decompressNone(input: []const u8, output: []u8, expected_size: usize) CompressionError!usize {
    _ = expected_size;
    if (output.len < input.len) return error.OutputTooSmall;
    @memcpy(output[0..input.len], input);
    return input.len;
}


fn compressDeflate(input: []const u8, output: []u8) CompressionError!usize {
    const Writer = std.Io.Writer;
    const flate = std.compress.flate;

    var out_writer: Writer = .fixed(output);
    var deflate_buf: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&out_writer, &deflate_buf, .raw, .level_1) catch
        return error.CompressionFailed;
    comp.writer.writeAll(input) catch return error.CompressionFailed;
    comp.writer.flush() catch return error.CompressionFailed;
    return out_writer.end;
}

fn decompressDeflate(input: []const u8, output: []u8) CompressionError!usize {
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const flate = std.compress.flate;

    var in_reader: Reader = .fixed(input);
    var decomp_buf: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&in_reader, .raw, &decomp_buf);

    var out_writer: Writer = .fixed(output);
    const total = decomp.reader.streamRemaining(&out_writer) catch
        return error.DecompressionFailed;
    return total;
}


fn compressZstd(input: []const u8, output: []u8) CompressionError!usize {
    if (!zstd_enabled) return error.UnsupportedAlgorithm;

    const result = zstd.ZSTD_compress(
        output.ptr,
        output.len,
        input.ptr,
        input.len,
        1,
    );

    if (zstd.ZSTD_isError(result) != 0) {
        return error.CompressionFailed;
    }

    return result;
}

fn decompressZstd(input: []const u8, output: []u8, expected_size: usize) CompressionError!usize {
    if (!zstd_enabled) return error.UnsupportedAlgorithm;

    _ = expected_size;
    const result = zstd.ZSTD_decompress(
        output.ptr,
        output.len,
        input.ptr,
        input.len,
    );

    if (zstd.ZSTD_isError(result) != 0) {
        return error.DecompressionFailed;
    }

    return result;
}


test "none compression round-trip" {
    const input = "Hello, world! This is test data for compression.";
    var compressed: [256]u8 = undefined;
    const comp_len = try compress(.none, input, &compressed);
    try std.testing.expectEqual(input.len, comp_len);

    var decompressed: [256]u8 = undefined;
    const decomp_len = try decompress(.none, compressed[0..comp_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..decomp_len]);
}

test "deflate compression round-trip" {
    var input: [4096]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast(i % 16);
    }

    var compressed: [8192]u8 = undefined;
    const comp_len = try compress(.deflate, &input, &compressed);

    try std.testing.expect(comp_len < input.len);

    var decompressed: [4096]u8 = undefined;
    const decomp_len = try decompress(.deflate, compressed[0..comp_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decomp_len]);
}
