const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const shared = @import("Shared");

/// Shader preprocessor that handles #fh_import directives
pub const ShaderPreprocessor = struct {
    const logger = shared.Logger.init("GlslPreprocessor");

    allocator: std.mem.Allocator,
    io: Io,
    /// Map of namespace -> base path (e.g., "farhorizons" -> "shaders/include/")
    namespace_paths: std.StringHashMap([]const u8),
    /// Track already included files to prevent circular imports
    included_files: std.StringHashMap(void),
    /// Maximum recursion depth for imports
    max_depth: u32 = 32,

    pub fn init(allocator: std.mem.Allocator, io: Io) ShaderPreprocessor {
        return .{
            .allocator = allocator,
            .io = io,
            .namespace_paths = std.StringHashMap([]const u8).init(allocator),
            .included_files = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ShaderPreprocessor) void {
        // Free namespace path keys and values
        var ns_iter = self.namespace_paths.iterator();
        while (ns_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.namespace_paths.deinit();

        // Free included files keys
        var inc_iter = self.included_files.iterator();
        while (inc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.included_files.deinit();
    }

    /// Register a namespace with its base path
    /// e.g., registerNamespace("farhorizons", "src/client/renderer/shaders/include/")
    pub fn registerNamespace(self: *ShaderPreprocessor, namespace: []const u8, base_path: []const u8) !void {
        const ns_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_copy);
        const path_copy = try self.allocator.dupe(u8, base_path);
        errdefer self.allocator.free(path_copy);

        try self.namespace_paths.put(ns_copy, path_copy);
    }

    /// Process shader source and resolve all #fh_import directives
    /// Returns the preprocessed source with all imports inlined
    pub fn process(self: *ShaderPreprocessor, source: []const u8) ![]const u8 {
        // Clear included files for new processing session
        var inc_iter = self.included_files.iterator();
        while (inc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.included_files.clearRetainingCapacity();

        return self.processInternal(source, 0);
    }

    /// Process shader source from a file path
    pub fn processFile(self: *ShaderPreprocessor, file_path: []const u8) ![]const u8 {
        const source = try self.readFile(file_path);
        defer self.allocator.free(source);
        return self.process(source);
    }

    fn processInternal(self: *ShaderPreprocessor, source: []const u8, depth: u32) ![]const u8 {
        if (depth > self.max_depth) {
            logger.err("Maximum import depth ({}) exceeded - possible circular import", .{self.max_depth});
            return error.MaxImportDepthExceeded;
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: usize = 0;

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.startsWith(u8, trimmed, "#fh_import")) {
                // Parse the import directive
                const import_path = try self.parseImportDirective(trimmed, line_num);
                defer self.allocator.free(import_path);

                // Check for circular import
                if (self.included_files.contains(import_path)) {
                    logger.warn("Skipping already included file: {s}", .{import_path});
                    // Add a comment noting the skip
                    try result.appendSlice(self.allocator, "// [already included: ");
                    try result.appendSlice(self.allocator, import_path);
                    try result.appendSlice(self.allocator, "]\n");
                    continue;
                }

                // Mark as included
                const path_copy = try self.allocator.dupe(u8, import_path);
                try self.included_files.put(path_copy, {});

                // Read and process the imported file
                const imported_source = self.readFile(import_path) catch |err| {
                    logger.err("Failed to read import '{s}': {}", .{ import_path, err });
                    return error.ImportReadFailed;
                };
                defer self.allocator.free(imported_source);

                // Recursively process imports in the included file
                const processed = try self.processInternal(imported_source, depth + 1);
                defer self.allocator.free(processed);

                // Add file boundary comments for debugging
                try result.appendSlice(self.allocator, "// --- BEGIN IMPORT: ");
                try result.appendSlice(self.allocator, import_path);
                try result.appendSlice(self.allocator, " ---\n");
                try result.appendSlice(self.allocator, processed);
                if (processed.len > 0 and processed[processed.len - 1] != '\n') {
                    try result.append(self.allocator, '\n');
                }
                try result.appendSlice(self.allocator, "// --- END IMPORT: ");
                try result.appendSlice(self.allocator, import_path);
                try result.appendSlice(self.allocator, " ---\n");
            } else {
                // Regular line - copy as-is
                try result.appendSlice(self.allocator, line);
                try result.append(self.allocator, '\n');
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Parse #fh_import <namespace:path> directive
    /// Returns the resolved file path
    fn parseImportDirective(self: *ShaderPreprocessor, line: []const u8, line_num: usize) ![]const u8 {
        // Expected format: #fh_import <namespace:path>
        const after_import = std.mem.trimStart(u8, line["#fh_import".len..], " \t");

        if (after_import.len == 0 or after_import[0] != '<') {
            logger.err("Line {}: Invalid #fh_import syntax, expected '<'", .{line_num});
            return error.InvalidImportSyntax;
        }

        const end_bracket = std.mem.indexOf(u8, after_import, ">") orelse {
            logger.err("Line {}: Invalid #fh_import syntax, missing '>'", .{line_num});
            return error.InvalidImportSyntax;
        };

        const import_spec = after_import[1..end_bracket];

        // Parse namespace:path
        const colon_pos = std.mem.indexOf(u8, import_spec, ":") orelse {
            logger.err("Line {}: Invalid import spec '{s}', expected 'namespace:path'", .{ line_num, import_spec });
            return error.InvalidImportSyntax;
        };

        const namespace = import_spec[0..colon_pos];
        const relative_path = import_spec[colon_pos + 1 ..];

        if (namespace.len == 0 or relative_path.len == 0) {
            logger.err("Line {}: Empty namespace or path in import", .{line_num});
            return error.InvalidImportSyntax;
        }

        // Resolve namespace to base path
        const base_path = self.namespace_paths.get(namespace) orelse {
            logger.err("Line {}: Unknown namespace '{s}'", .{ line_num, namespace });
            return error.UnknownNamespace;
        };

        // Combine base path and relative path
        return Dir.path.join(self.allocator, &.{ base_path, relative_path });
    }

    fn readFile(self: *ShaderPreprocessor, path: []const u8) ![]const u8 {
        const file = Dir.cwd().openFile(self.io, path, .{}) catch |err| {
            logger.err("Cannot open file '{s}': {}", .{ path, err });
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const size: usize = @intCast(stat.size);
        if (size > 1024 * 1024) { // 1MB limit
            return error.FileTooLarge;
        }

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try file.readPositionalAll(self.io, buffer, 0);
        if (bytes_read != size) {
            return error.UnexpectedEOF;
        }

        return buffer;
    }
};

// Tests
test "parse simple import" {
    const allocator = std.testing.allocator;

    var preprocessor = ShaderPreprocessor.init(allocator, std.testing.io);
    defer preprocessor.deinit();

    try preprocessor.registerNamespace("farhorizons", "shaders/include");

    // This would need actual files to test fully
}

test "detect circular import" {
    // Test circular import detection logic
}
