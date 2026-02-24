const std = @import("std");
const storage_types = @import("types.zig");
const build_options = @import("build_options");

const CompressionAlgo = storage_types.CompressionAlgo;

// ── ZSTD C bindings (optional, enabled via -Dzstd=true) ────────────

pub const zstd_enabled = build_options.zstd_enabled;

const zstd = if (zstd_enabled) @cImport(@cInclude("zstd.h")) else struct {};

// ── Compression ────────────────────────────────────────────────────

pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    UnsupportedAlgorithm,
    OutputTooSmall,
    OutOfMemory,
};

/// Compress `input` using the specified algorithm into `output`.
/// Returns the number of compressed bytes written to `output`.
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

/// Decompress `input` using the specified algorithm into `output`.
/// `expected_size` is the known decompressed size.
/// Returns the number of decompressed bytes.
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

/// Returns a conservative upper bound on compressed size for a given input size.
pub fn compressBound(algo: CompressionAlgo, input_size: usize) usize {
    return switch (algo) {
        .none => input_size,
        .deflate => input_size + input_size / 7 + 64, // deflate overhead estimate
        .zstd => if (zstd_enabled)
            zstd.ZSTD_compressBound(input_size)
        else
            input_size + input_size / 4 + 64,
    };
}

// ── None (passthrough) ─────────────────────────────────────────────

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

// ── Deflate (using Zig stdlib) ─────────────────────────────────────

fn compressDeflate(input: []const u8, output: []u8) CompressionError!usize {
    var fbs = std.io.fixedBufferStream(output);
    var comp = std.compress.flate.compressor(.raw, fbs.writer(), .{}) catch
        return error.CompressionFailed;
    comp.write(input) catch return error.CompressionFailed;
    comp.finish() catch return error.CompressionFailed;
    return fbs.pos;
}

fn decompressDeflate(input: []const u8, output: []u8) CompressionError!usize {
    var in_stream = std.io.fixedBufferStream(input);
    var decomp = std.compress.flate.decompressor(.raw, in_stream.reader());
    var total: usize = 0;
    while (total < output.len) {
        const n = decomp.read(output[total..]) catch return error.DecompressionFailed;
        if (n == 0) break;
        total += n;
    }
    return total;
}

// ── ZSTD (via C libzstd) ──────────────────────────────────────────

fn compressZstd(input: []const u8, output: []u8) CompressionError!usize {
    if (!zstd_enabled) return error.UnsupportedAlgorithm;

    const result = zstd.ZSTD_compress(
        output.ptr,
        output.len,
        input.ptr,
        input.len,
        1, // compression level 1 (fast)
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

// ── Tests ──────────────────────────────────────────────────────────

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
    // Create compressible data (repeating pattern)
    var input: [4096]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast(i % 16);
    }

    var compressed: [8192]u8 = undefined;
    const comp_len = try compress(.deflate, &input, &compressed);

    // Deflate should compress the repeating pattern well
    try std.testing.expect(comp_len < input.len);

    var decompressed: [4096]u8 = undefined;
    const decomp_len = try decompress(.deflate, compressed[0..comp_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decomp_len]);
}
