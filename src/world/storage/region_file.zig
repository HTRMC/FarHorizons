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

pub const RegionFile = struct {
    file: File,
    io: Io,
    coord: RegionCoord,
    header: FileHeader,
    cot: [CHUNKS_PER_REGION]ChunkOffsetEntry,
    allocator_bitmap: SectorAllocator,
    active_slot: u1,
    rw_lock: std.Io.RwLock,
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

        const file = Dir.openFileAbsolute(io, full_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => {
                return createNew(mem_alloc, io, full_path, coord);
            },
            else => {
                log.err("Failed to open region file '{s}': {}", .{ full_path, err });
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
        const file = Dir.createFileAbsolute(io, path, .{ .read = true }) catch |err| {
            log.err("Failed to create region file '{s}': {}", .{ path, err });
            mem_alloc.free(path);
            return error.IoError;
        };
        errdefer file.close(io);

        const self = try mem_alloc.create(RegionFile);
        errdefer mem_alloc.destroy(self);

        const c_time = struct {
            extern "c" fn time(timer: ?*i64) i64;
        };
        const timestamp: u32 = @intCast(@max(0, c_time.time(null)));

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
            .active_slot = 0,
            .rw_lock = .init,
            .ref_count = std.atomic.Value(u32).init(1),
            .path = path,
            .mem_allocator = mem_alloc,
        };

        self.writeSlot(0) catch |err| {
            log.err("Failed to write initial slot A: {}", .{err});
            return err;
        };
        self.writeSlot(1) catch |err| {
            log.err("Failed to write initial slot B: {}", .{err});
            return err;
        };
        self.fsync() catch {};

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
            .active_slot = 0,
            .rw_lock = .init,
            .ref_count = std.atomic.Value(u32).init(1),
            .path = path,
            .mem_allocator = mem_alloc,
        };

        try self.readHeader();

        self.allocator_bitmap = SectorAllocator.rebuildFromCot(&self.cot);

        return self;
    }

    pub fn close(self: *RegionFile) void {
        self.file.close(self.io);
        self.mem_allocator.free(self.path);
        self.mem_allocator.destroy(self);
    }

    pub fn ref(self: *RegionFile) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *RegionFile) bool {
        return self.ref_count.fetchSub(1, .release) == 1;
    }


    pub fn readChunkRaw(self: *RegionFile, chunk_index: u9) !?[]u8 {
        self.rw_lock.lockSharedUncancelable(self.io);
        defer self.rw_lock.unlockShared(self.io);

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

    pub fn readChunk(
        self: *RegionFile,
        chunk_index: u9,
        out_blocks: *[WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType,
    ) !bool {
        const raw_result = try self.readChunkRawWithAlgo(chunk_index) orelse return false;
        defer self.mem_allocator.free(raw_result.data);

        const algo = raw_result.algo;

        var decompressed_buf: [64 * 1024]u8 = undefined;
        if (algo == .none) {
            try chunk_codec.decode(raw_result.data, out_blocks);
        } else {
            const decompressed_len = try compression.decompress(
                algo,
                raw_result.data,
                &decompressed_buf,
                decompressed_buf.len,
            );
            try chunk_codec.decode(decompressed_buf[0..decompressed_len], out_blocks);
        }

        return true;
    }


    pub fn writeChunk(
        self: *RegionFile,
        chunk_index: u9,
        blocks: *const [WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType,
        algo: CompressionAlgo,
    ) !void {
        var encoded = try chunk_codec.encode(self.mem_allocator, blocks);
        defer encoded.deinit();

        var compressed_buf: [256 * 1024]u8 = undefined;
        const compressed_data: []const u8 = if (algo == .none)
            encoded.data
        else blk: {
            const len = try compression.compress(algo, encoded.data, &compressed_buf);
            break :blk compressed_buf[0..len];
        };

        const sectors_needed = storage_types.sectorsNeeded(compressed_data.len);
        if (sectors_needed == 0) return;

        self.rw_lock.lockUncancelable(self.io);
        defer self.rw_lock.unlock(self.io);

        const new_offset = self.allocator_bitmap.allocate(sectors_needed) orelse
            return error.OutOfSpace;

        const file_offset: u64 = @as(u64, new_offset) * SECTOR_SIZE;
        self.pwriteAll(compressed_data, file_offset) catch {
            self.allocator_bitmap.free(new_offset, sectors_needed);
            return error.IoError;
        };

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

        try self.commitHeader();
    }

    pub fn writeChunkBatch(
        self: *RegionFile,
        chunk_indices: []const u9,
        block_arrays: []const *const [WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType,
        algo: CompressionAlgo,
    ) !void {
        if (chunk_indices.len == 0) return;
        std.debug.assert(chunk_indices.len == block_arrays.len);

        self.rw_lock.lockUncancelable(self.io);
        defer self.rw_lock.unlock(self.io);

        var old_entries: [20]struct { offset: u24, count: u8 } = undefined;
        var old_count: usize = 0;

        var compressed_buf: [256 * 1024]u8 = undefined;

        for (0..chunk_indices.len) |i| {
            const chunk_index = chunk_indices[i];
            const blocks = block_arrays[i];

            var encoded = chunk_codec.encode(self.mem_allocator, blocks) catch |err| {
                log.err("Batch encode failed for chunk {d}: {}", .{ chunk_index, err });
                continue;
            };
            defer encoded.deinit();

            const compressed_data: []const u8 = if (algo == .none)
                encoded.data
            else blk: {
                const len = compression.compress(algo, encoded.data, &compressed_buf) catch |err| {
                    log.err("Batch compress failed for chunk {d}: {}", .{ chunk_index, err });
                    continue;
                };
                break :blk compressed_buf[0..len];
            };

            const sectors_needed = storage_types.sectorsNeeded(compressed_data.len);
            if (sectors_needed == 0) continue;

            const new_offset = self.allocator_bitmap.allocate(sectors_needed) orelse {
                log.err("Batch: out of space for chunk {d}", .{chunk_index});
                continue;
            };

            const file_offset: u64 = @as(u64, new_offset) * SECTOR_SIZE;
            self.pwriteAll(compressed_data, file_offset) catch {
                self.allocator_bitmap.free(new_offset, sectors_needed);
                log.err("Batch: write failed for chunk {d}", .{chunk_index});
                continue;
            };

            const old_entry = self.cot[chunk_index];
            if (old_entry.isPresent() and old_count < old_entries.len) {
                old_entries[old_count] = .{ .offset = old_entry.sector_offset, .count = old_entry.sector_count };
                old_count += 1;
            }

            self.cot[chunk_index] = .{
                .sector_offset = new_offset,
                .sector_count = sectors_needed,
                .compressed_size = @intCast(compressed_data.len),
                .compression = @intFromEnum(algo),
                .flags = 0,
            };
        }

        for (old_entries[0..old_count]) |old| {
            self.allocator_bitmap.free(old.offset, old.count);
        }

        self.header.generation += 1;
        self.header.total_sectors = self.allocator_bitmap.total_sectors;

        try self.commitHeader();
    }

    pub fn chunkExists(self: *RegionFile, chunk_index: u9) bool {
        self.rw_lock.lockSharedUncancelable(self.io);
        defer self.rw_lock.unlockShared(self.io);
        return self.cot[chunk_index].isPresent();
    }

    fn readChunkRawWithAlgo(self: *RegionFile, chunk_index: u9) !?struct { data: []u8, algo: CompressionAlgo } {
        self.rw_lock.lockSharedUncancelable(self.io);
        defer self.rw_lock.unlockShared(self.io);

        const entry = self.cot[chunk_index];
        if (!entry.isPresent()) return null;

        const offset: u64 = @as(u64, entry.sector_offset) * SECTOR_SIZE;
        const size: usize = entry.compressed_size;

        const buf = try self.mem_allocator.alloc(u8, size);
        errdefer self.mem_allocator.free(buf);

        self.preadAll(buf, offset) catch {
            return error.IoError;
        };

        return .{ .data = buf, .algo = entry.compressionAlgo() };
    }

    fn readHeader(self: *RegionFile) !void {
        var buf: [HEADER_SECTORS * SECTOR_SIZE]u8 = undefined;
        self.preadAll(&buf, 0) catch return error.IoError;

        const valid_a = verifyMetaPage(buf[storage_types.OFFSET_META_A..][0..SECTOR_SIZE]);
        const valid_b = verifyMetaPage(buf[storage_types.OFFSET_META_B..][0..SECTOR_SIZE]);

        if (!valid_a and !valid_b) {
            log.err("Both meta pages have bad CRC — corrupt region file {s}", .{self.path});
            return error.CorruptHeader;
        }

        const use_slot: u1 = if (valid_a and valid_b) blk: {
            const gen_a = parseMetaGeneration(buf[storage_types.OFFSET_META_A..][0..SECTOR_SIZE]);
            const gen_b = parseMetaGeneration(buf[storage_types.OFFSET_META_B..][0..SECTOR_SIZE]);
            break :blk if (gen_b > gen_a) @as(u1, 1) else @as(u1, 0);
        } else if (valid_a) @as(u1, 0) else @as(u1, 1);

        self.active_slot = use_slot;

        const meta_offset: usize = if (use_slot == 0) storage_types.OFFSET_META_A else storage_types.OFFSET_META_B;
        const meta_page = buf[meta_offset..][0..SECTOR_SIZE];
        self.header = @as(*const FileHeader, @ptrCast(@alignCast(meta_page[storage_types.META_OFFSET_HEADER..][0..@sizeOf(FileHeader)]))).*;

        if (!self.header.validate()) {
            return error.InvalidMagic;
        }

        self.allocator_bitmap.loadBitmap(
            @ptrCast(meta_page[storage_types.META_OFFSET_BITMAP..][0..storage_types.BITMAP_BYTES]),
        );

        const cot_offset: usize = if (use_slot == 0) storage_types.OFFSET_COT_A else storage_types.OFFSET_COT_B;
        const cot_bytes = buf[cot_offset..][0 .. CHUNKS_PER_REGION * @sizeOf(ChunkOffsetEntry)];
        const cot_entries: [*]const ChunkOffsetEntry = @ptrCast(@alignCast(cot_bytes.ptr));
        @memcpy(&self.cot, cot_entries[0..CHUNKS_PER_REGION]);

        log.info("Opened region file {s} (slot {c}, gen {d})", .{
            self.path,
            @as(u8, if (use_slot == 0) 'A' else 'B'),
            self.header.generation,
        });
    }

    fn commitHeader(self: *RegionFile) !void {
        const inactive: u1 = self.active_slot ^ 1;

        const cot_offset: u64 = if (inactive == 0) storage_types.OFFSET_COT_A else storage_types.OFFSET_COT_B;
        const cot_data: [*]const u8 = @ptrCast(&self.cot);
        self.pwriteAll(cot_data[0 .. CHUNKS_PER_REGION * @sizeOf(ChunkOffsetEntry)], cot_offset) catch
            return error.IoError;

        self.fsync() catch {};

        var meta_page: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;

        const header_bytes: [*]const u8 = @ptrCast(&self.header);
        @memcpy(meta_page[storage_types.META_OFFSET_HEADER..][0..@sizeOf(FileHeader)], header_bytes[0..@sizeOf(FileHeader)]);

        @memcpy(
            meta_page[storage_types.META_OFFSET_BITMAP..][0..storage_types.BITMAP_BYTES],
            self.allocator_bitmap.getBitmap(),
        );

        const crc = storage_types.crc32(meta_page[0..storage_types.META_OFFSET_CRC]);
        const crc_bytes: [4]u8 = @bitCast(crc);
        @memcpy(meta_page[storage_types.META_OFFSET_CRC..][0..4], &crc_bytes);

        const meta_offset: u64 = if (inactive == 0) storage_types.OFFSET_META_A else storage_types.OFFSET_META_B;
        self.pwriteAll(&meta_page, meta_offset) catch return error.IoError;

        self.fsync() catch {};

        self.active_slot = inactive;
    }

    fn writeSlot(self: *RegionFile, slot: u1) !void {
        const cot_offset: u64 = if (slot == 0) storage_types.OFFSET_COT_A else storage_types.OFFSET_COT_B;
        const cot_data: [*]const u8 = @ptrCast(&self.cot);
        self.pwriteAll(cot_data[0 .. CHUNKS_PER_REGION * @sizeOf(ChunkOffsetEntry)], cot_offset) catch
            return error.IoError;

        var meta_page: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;

        const header_bytes: [*]const u8 = @ptrCast(&self.header);
        @memcpy(meta_page[storage_types.META_OFFSET_HEADER..][0..@sizeOf(FileHeader)], header_bytes[0..@sizeOf(FileHeader)]);

        @memcpy(
            meta_page[storage_types.META_OFFSET_BITMAP..][0..storage_types.BITMAP_BYTES],
            self.allocator_bitmap.getBitmap(),
        );

        const crc = storage_types.crc32(meta_page[0..storage_types.META_OFFSET_CRC]);
        const crc_bytes: [4]u8 = @bitCast(crc);
        @memcpy(meta_page[storage_types.META_OFFSET_CRC..][0..4], &crc_bytes);

        const meta_offset: u64 = if (slot == 0) storage_types.OFFSET_META_A else storage_types.OFFSET_META_B;
        self.pwriteAll(&meta_page, meta_offset) catch return error.IoError;
    }

    fn verifyMetaPage(page: *const [SECTOR_SIZE]u8) bool {
        const stored_crc = std.mem.readInt(u32, page[storage_types.META_OFFSET_CRC..][0..4], .little);
        const computed_crc = storage_types.crc32(page[0..storage_types.META_OFFSET_CRC]);
        return stored_crc == computed_crc;
    }

    fn parseMetaGeneration(page: *const [SECTOR_SIZE]u8) u32 {
        const hdr = @as(*const FileHeader, @ptrCast(@alignCast(page[0..@sizeOf(FileHeader)])));
        return hdr.generation;
    }


    fn preadAll(self: *const RegionFile, buf: []u8, offset: u64) !void {
        const n = self.file.readPositionalAll(self.io, buf, offset) catch
            return error.IoError;
        if (n < buf.len) return error.IoError;
    }

    fn pwriteAll(self: *const RegionFile, data: []const u8, offset: u64) !void {
        self.file.writePositionalAll(self.io, data, offset) catch
            return error.IoError;
    }

    pub fn fsync(self: *const RegionFile) !void {
        self.file.sync(self.io) catch return error.IoError;
    }
};
