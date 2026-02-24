const std = @import("std");
const storage_types = @import("types.zig");
const SectorAllocator = @import("sector_allocator.zig").SectorAllocator;
const compression = @import("compression.zig");
const chunk_codec = @import("chunk_codec.zig");
const WorldState = @import("../WorldState.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const SECTOR_SIZE = storage_types.SECTOR_SIZE;
const HEADER_SECTORS = storage_types.HEADER_SECTORS;
const CHUNKS_PER_REGION = storage_types.CHUNKS_PER_REGION;
const ChunkOffsetEntry = storage_types.ChunkOffsetEntry;
const FileHeader = storage_types.FileHeader;
const RegionCoord = storage_types.RegionCoord;
const CompressionAlgo = storage_types.CompressionAlgo;
const ChunkKey = storage_types.ChunkKey;

const log = std.log.scoped(.region_file);

/// A region file manages 512 chunks (8x8x8) in a single .fhr file.
/// Supports concurrent readers via COW writes — readers never see partial writes.
pub const RegionFile = struct {
    file: File,
    io: Io,
    coord: RegionCoord,
    header: FileHeader,
    cot: [CHUNKS_PER_REGION]ChunkOffsetEntry,
    allocator_bitmap: SectorAllocator,
    rw_lock: std.Thread.RwLock,
    ref_count: std.atomic.Value(u32),
    path: []const u8,
    mem_allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidMagic,
        InvalidVersion,
        CorruptHeader,
        IoError,
        OutOfSpace,
        ChunkNotPresent,
    } || std.mem.Allocator.Error || compression.CompressionError || chunk_codec.DecodeError;

    /// Open an existing region file or create a new one.
    pub fn open(
        mem_alloc: std.mem.Allocator,
        dir_path: []const u8,
        coord: RegionCoord,
    ) !*RegionFile {
        const io = Io.Threaded.global_single_threaded.io();
        const file_name = try std.fmt.allocPrint(
            mem_alloc,
            "r.{d}.{d}.{d}.fhr",
            .{ coord.rx, coord.ry, coord.rz },
        );
        defer mem_alloc.free(file_name);

        const sep = std.fs.path.sep_str;
        const full_path = try std.fmt.allocPrint(
            mem_alloc,
            "{s}{s}{s}",
            .{ dir_path, sep, file_name },
        );

        // Try to open existing file
        const file = Dir.openFileAbsolute(io, full_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => {
                // Create new file
                return createNew(mem_alloc, io, full_path, coord);
            },
            else => {
                mem_alloc.free(full_path);
                return error.IoError;
            },
        };

        return openExisting(mem_alloc, io, file, full_path, coord) catch |err| {
            file.close(io);
            mem_alloc.free(full_path);
            return err;
        };
    }

    fn createNew(
        mem_alloc: std.mem.Allocator,
        io: Io,
        path: []const u8,
        coord: RegionCoord,
    ) !*RegionFile {
        const file = Dir.createFileAbsolute(io, path, .{}) catch {
            mem_alloc.free(path);
            return error.IoError;
        };
        errdefer file.close(io);

        const self = try mem_alloc.create(RegionFile);
        errdefer mem_alloc.destroy(self);

        const timestamp: u32 = @intCast(@max(0, std.time.timestamp()));

        self.* = .{
            .file = file,
            .io = io,
            .coord = coord,
            .header = .{
                .lod_level = coord.lod,
                .region_x = coord.rx,
                .region_y = coord.ry,
                .region_z = coord.rz,
                .creation_timestamp = timestamp,
                .total_sectors = HEADER_SECTORS,
                .generation = 0,
            },
            .cot = [_]ChunkOffsetEntry{ChunkOffsetEntry.empty} ** CHUNKS_PER_REGION,
            .allocator_bitmap = SectorAllocator.init(),
            .rw_lock = .{},
            .ref_count = std.atomic.Value(u32).init(1),
            .path = path,
            .mem_allocator = mem_alloc,
        };

        // Write initial header to disk
        try self.writeHeaderToDisk();

        return self;
    }

    fn openExisting(
        mem_alloc: std.mem.Allocator,
        io: Io,
        file: File,
        path: []const u8,
        coord: RegionCoord,
    ) !*RegionFile {
        const self = try mem_alloc.create(RegionFile);
        errdefer mem_alloc.destroy(self);

        self.* = .{
            .file = file,
            .io = io,
            .coord = coord,
            .header = undefined,
            .cot = undefined,
            .allocator_bitmap = undefined,
            .rw_lock = .{},
            .ref_count = std.atomic.Value(u32).init(1),
            .path = path,
            .mem_allocator = mem_alloc,
        };

        try self.readHeader();

        // Validate header
        if (!self.header.validate()) {
            return error.InvalidMagic;
        }

        // Verify CRC32
        if (!self.verifyCrc()) {
            log.warn("CRC32 mismatch for region file {s}, rebuilding from COT", .{path});
        }

        // Rebuild sector allocator from COT (the COT is the source of truth)
        self.allocator_bitmap = SectorAllocator.rebuildFromCot(&self.cot);

        return self;
    }

    /// Close the region file and free resources.
    pub fn close(self: *RegionFile) void {
        self.file.close(self.io);
        self.mem_allocator.free(self.path);
        self.mem_allocator.destroy(self);
    }

    /// Increment reference count.
    pub fn ref(self: *RegionFile) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count. Returns true if this was the last reference.
    pub fn unref(self: *RegionFile) bool {
        return self.ref_count.fetchSub(1, .release) == 1;
    }

    // ── Read Path ──────────────────────────────────────────────────

    /// Read a chunk's compressed data from disk.
    /// Does NOT require a lock — COW writes guarantee data is immutable once referenced by the COT.
    pub fn readChunkRaw(self: *RegionFile, chunk_index: u9) !?[]u8 {
        const entry = self.cot[chunk_index];
        if (!entry.isPresent()) return null;

        const offset: u64 = @as(u64, entry.sector_offset) * SECTOR_SIZE;
        const size: usize = entry.compressed_size;

        const buf = try self.mem_allocator.alloc(u8, size);
        errdefer self.mem_allocator.free(buf);

        self.preadAll(buf, offset) catch {
            return error.IoError;
        };

        return buf;
    }

    /// Read and decompress+decode a chunk into a block array.
    pub fn readChunk(
        self: *RegionFile,
        chunk_index: u9,
        out_blocks: *[WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType,
    ) !bool {
        const raw = try self.readChunkRaw(chunk_index) orelse return false;
        defer self.mem_allocator.free(raw);

        const entry = self.cot[chunk_index];
        const algo = entry.compressionAlgo();

        // Decompress
        var decompressed_buf: [64 * 1024]u8 = undefined; // 64 KB should be enough
        if (algo == .none) {
            try chunk_codec.decode(raw, out_blocks);
        } else {
            const decompressed_len = try compression.decompress(
                algo,
                raw,
                &decompressed_buf,
                decompressed_buf.len,
            );
            try chunk_codec.decode(decompressed_buf[0..decompressed_len], out_blocks);
        }

        return true;
    }

    // ── Write Path (COW) ───────────────────────────────────────────

    /// Write a chunk using copy-on-write for crash safety.
    /// Serializes + compresses the chunk, allocates new sectors, writes data,
    /// then atomically updates the COT header.
    pub fn writeChunk(
        self: *RegionFile,
        chunk_index: u9,
        blocks: *const [WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType,
        algo: CompressionAlgo,
    ) !void {
        // Step 1: Serialize + compress OUTSIDE the lock
        var encoded = try chunk_codec.encode(self.mem_allocator, blocks);
        defer encoded.deinit();

        var compressed_buf: [256 * 1024]u8 = undefined; // 256 KB
        const compressed_data: []const u8 = if (algo == .none)
            encoded.data
        else blk: {
            const len = try compression.compress(algo, encoded.data, &compressed_buf);
            break :blk compressed_buf[0..len];
        };

        const sectors_needed = storage_types.sectorsNeeded(compressed_data.len);
        if (sectors_needed == 0) return;

        // Step 2: Acquire write lock
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        // Step 3: Allocate new sectors
        const new_offset = self.allocator_bitmap.allocate(sectors_needed) orelse
            return error.OutOfSpace;

        // Step 4: Write compressed data to new sectors
        const file_offset: u64 = @as(u64, new_offset) * SECTOR_SIZE;
        self.pwriteAll(compressed_data, file_offset) catch {
            // Rollback allocation on write failure
            self.allocator_bitmap.free(new_offset, sectors_needed);
            return error.IoError;
        };

        // Step 5: Sync data to disk
        self.fsync() catch {};

        // Step 6: Update COT entry + free old sectors
        const old_entry = self.cot[chunk_index];
        if (old_entry.isPresent()) {
            self.allocator_bitmap.free(old_entry.sector_offset, old_entry.sector_count);
        }

        self.cot[chunk_index] = .{
            .sector_offset = new_offset,
            .sector_count = sectors_needed,
            .compressed_size = @intCast(compressed_data.len),
            .compression = @intFromEnum(algo),
            .flags = 0,
        };

        self.header.generation += 1;
        self.header.total_sectors = self.allocator_bitmap.total_sectors;

        // Step 7: Write header (2 sectors)
        try self.writeHeaderToDisk();

        // Step 8: Sync header to disk
        self.fsync() catch {};
    }

    /// Check if a chunk exists in this region file.
    pub fn chunkExists(self: *const RegionFile, chunk_index: u9) bool {
        return self.cot[chunk_index].isPresent();
    }

    // ── Header I/O ─────────────────────────────────────────────────

    fn readHeader(self: *RegionFile) !void {
        // Read both header sectors (8192 bytes total)
        var header_buf: [HEADER_SECTORS * SECTOR_SIZE]u8 = undefined;
        self.preadAll(&header_buf, 0) catch return error.IoError;

        // Parse file header (first 32 bytes)
        self.header = @as(*const FileHeader, @ptrCast(@alignCast(header_buf[0..@sizeOf(FileHeader)]))).*;

        // Parse COT entries 0..507 from sector 0
        const cot_first_bytes = header_buf[storage_types.OFFSET_COT_FIRST..][0 .. storage_types.COT_SPLIT_FIRST * 8];
        const cot_first: [*]const ChunkOffsetEntry = @ptrCast(@alignCast(cot_first_bytes.ptr));
        @memcpy(self.cot[0..storage_types.COT_SPLIT_FIRST], cot_first[0..storage_types.COT_SPLIT_FIRST]);

        // Parse COT entries 508..511 from sector 1
        const cot_second_bytes = header_buf[storage_types.OFFSET_COT_SECOND..][0 .. storage_types.COT_SPLIT_SECOND * 8];
        const cot_second: [*]const ChunkOffsetEntry = @ptrCast(@alignCast(cot_second_bytes.ptr));
        @memcpy(
            self.cot[storage_types.COT_SPLIT_FIRST..][0..storage_types.COT_SPLIT_SECOND],
            cot_second[0..storage_types.COT_SPLIT_SECOND],
        );
    }

    fn writeHeaderToDisk(self: *RegionFile) !void {
        var header_buf: [HEADER_SECTORS * SECTOR_SIZE]u8 = [_]u8{0} ** (HEADER_SECTORS * SECTOR_SIZE);

        // Write file header
        const header_bytes: [*]const u8 = @ptrCast(&self.header);
        @memcpy(header_buf[0..@sizeOf(FileHeader)], header_bytes[0..@sizeOf(FileHeader)]);

        // Write COT entries 0..507
        const cot_first: [*]const u8 = @ptrCast(&self.cot[0]);
        @memcpy(
            header_buf[storage_types.OFFSET_COT_FIRST..][0 .. storage_types.COT_SPLIT_FIRST * 8],
            cot_first[0 .. storage_types.COT_SPLIT_FIRST * 8],
        );

        // Write COT entries 508..511
        const cot_second: [*]const u8 = @ptrCast(&self.cot[storage_types.COT_SPLIT_FIRST]);
        @memcpy(
            header_buf[storage_types.OFFSET_COT_SECOND..][0 .. storage_types.COT_SPLIT_SECOND * 8],
            cot_second[0 .. storage_types.COT_SPLIT_SECOND * 8],
        );

        // Compute and write CRC32 (covers bytes 0x0000..0x101F)
        const crc = storage_types.crc32(header_buf[0..storage_types.OFFSET_CRC32]);
        const crc_bytes: [4]u8 = @bitCast(crc);
        @memcpy(header_buf[storage_types.OFFSET_CRC32..][0..4], &crc_bytes);

        // Write bitmap
        @memcpy(
            header_buf[storage_types.OFFSET_BITMAP..][0..storage_types.BITMAP_BYTES],
            self.allocator_bitmap.getBitmap(),
        );

        // Write both sectors
        self.pwriteAll(&header_buf, 0) catch return error.IoError;
    }

    fn verifyCrc(self: *const RegionFile) bool {
        // Re-read header from disk and verify CRC
        var header_buf: [storage_types.OFFSET_CRC32 + 4]u8 = undefined;
        self.preadAll(&header_buf, 0) catch return false;

        const stored_crc = std.mem.readInt(u32, header_buf[storage_types.OFFSET_CRC32..][0..4], .little);
        const computed_crc = storage_types.crc32(header_buf[0..storage_types.OFFSET_CRC32]);
        return stored_crc == computed_crc;
    }

    // ── Low-level file I/O helpers ─────────────────────────────────

    fn preadAll(self: *const RegionFile, buf: []u8, offset: u64) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = self.file.pread(self.io, buf[total..], offset + total) catch
                return error.IoError;
            if (n == 0) return error.IoError; // unexpected EOF
            total += n;
        }
    }

    fn pwriteAll(self: *const RegionFile, data: []const u8, offset: u64) !void {
        var total: usize = 0;
        while (total < data.len) {
            const n = self.file.pwrite(self.io, data[total..], offset + total) catch
                return error.IoError;
            total += n;
        }
    }

    pub fn fsync(self: *const RegionFile) !void {
        self.file.sync(self.io) catch return error.IoError;
    }
};
