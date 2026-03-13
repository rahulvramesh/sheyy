//! Memory Cortex: persistent JSON-based memory storage for agents
//! Stores memories in memory/cortex.json with search, stats, and clear operations.
const std = @import("std");

pub const MemoryEntry = struct {
    id: u64, // timestamp-based unique ID
    content: []const u8,
    tags: []const []const u8,
    timestamp: i64, // unix epoch seconds
    source: []const u8, // "user" or "agent"
};

const SavedEntry = struct {
    id: u64,
    content: []const u8,
    tags: []const []const u8 = &.{},
    timestamp: i64,
    source: []const u8,
};

const SavedCortex = struct {
    version: u32 = 1,
    entries: []const SavedEntry,
};

pub const MemoryCortex = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(MemoryEntry),
    file_path: []const u8,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator, persist_dir: []const u8) !MemoryCortex {
        const file_path = try std.fs.path.join(allocator, &.{ persist_dir, "cortex.json" });

        var cortex = MemoryCortex{
            .allocator = allocator,
            .entries = .empty,
            .file_path = file_path,
            .next_id = @intCast(@as(u64, @bitCast(std.time.timestamp()))),
        };

        cortex.load();
        return cortex;
    }

    pub fn deinit(self: *MemoryCortex) void {
        for (self.entries.items) |entry| freeEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.file_path);
    }

    fn freeEntry(allocator: std.mem.Allocator, entry: MemoryEntry) void {
        allocator.free(entry.content);
        allocator.free(entry.source);
        for (entry.tags) |tag| allocator.free(tag);
        allocator.free(entry.tags);
    }

    /// Add a new memory entry. Tags are extracted from content (#tag syntax) plus any explicit tags.
    pub fn add(self: *MemoryCortex, content: []const u8, source: []const u8, extra_tags: []const []const u8) !void {
        // Extract hashtags from content
        var auto_tags: std.ArrayList([]const u8) = .empty;
        defer auto_tags.deinit(self.allocator);

        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '#' and (i == 0 or content[i - 1] == ' ')) {
                const tag_start = i + 1;
                var tag_end = tag_start;
                while (tag_end < content.len and content[tag_end] != ' ' and content[tag_end] != '\n') {
                    tag_end += 1;
                }
                if (tag_end > tag_start) {
                    try auto_tags.append(self.allocator, try self.allocator.dupe(u8, content[tag_start..tag_end]));
                }
                i = tag_end;
            } else {
                i += 1;
            }
        }

        // Add explicit tags
        for (extra_tags) |tag| {
            try auto_tags.append(self.allocator, try self.allocator.dupe(u8, tag));
        }

        const tags = try auto_tags.toOwnedSlice(self.allocator);

        const entry = MemoryEntry{
            .id = self.next_id,
            .content = try self.allocator.dupe(u8, content),
            .tags = tags,
            .timestamp = std.time.timestamp(),
            .source = try self.allocator.dupe(u8, source),
        };
        self.next_id += 1;

        try self.entries.append(self.allocator, entry);
        self.save();
    }

    /// Search memories by query string. Matches against content and tags (case-insensitive).
    pub fn search(self: *MemoryCortex, query: []const u8) ![]const MemoryEntry {
        var results: std.ArrayList(MemoryEntry) = .empty;
        defer results.deinit(self.allocator);

        // Lowercase the query for case-insensitive matching
        const query_lower = try self.allocator.alloc(u8, query.len);
        defer self.allocator.free(query_lower);
        for (query, 0..) |c, idx| {
            query_lower[idx] = std.ascii.toLower(c);
        }

        for (self.entries.items) |entry| {
            if (matchesQuery(self.allocator, entry, query_lower)) {
                try results.append(self.allocator, entry);
            }
        }

        return try results.toOwnedSlice(self.allocator);
    }

    fn matchesQuery(allocator: std.mem.Allocator, entry: MemoryEntry, query_lower: []const u8) bool {
        // Check content (case-insensitive)
        const content_lower = allocator.alloc(u8, entry.content.len) catch return false;
        defer allocator.free(content_lower);
        for (entry.content, 0..) |c, i| {
            content_lower[i] = std.ascii.toLower(c);
        }
        if (std.mem.indexOf(u8, content_lower, query_lower) != null) return true;

        // Check tags
        for (entry.tags) |tag| {
            const tag_lower = allocator.alloc(u8, tag.len) catch continue;
            defer allocator.free(tag_lower);
            for (tag, 0..) |c, i| {
                tag_lower[i] = std.ascii.toLower(c);
            }
            if (std.mem.indexOf(u8, tag_lower, query_lower) != null) return true;
        }

        return false;
    }

    /// Return memory statistics as a formatted string.
    pub fn stats(self: *MemoryCortex) ![]const u8 {
        var tag_counts = std.StringHashMap(usize).init(self.allocator);
        defer tag_counts.deinit();

        var user_count: usize = 0;
        var agent_count: usize = 0;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.source, "user")) {
                user_count += 1;
            } else {
                agent_count += 1;
            }
            for (entry.tags) |tag| {
                const result = try tag_counts.getOrPut(tag);
                if (result.found_existing) {
                    result.value_ptr.* += 1;
                } else {
                    result.value_ptr.* = 1;
                }
            }
        }

        var buf: std.ArrayList(u8) = .empty;
        const w = buf.writer(self.allocator);

        try w.print("Memory Cortex Stats\n\n", .{});
        try w.print("Total memories: {d}\n", .{self.entries.items.len});
        try w.print("  From user: {d}\n", .{user_count});
        try w.print("  From agent: {d}\n", .{agent_count});

        if (tag_counts.count() > 0) {
            try w.print("\nTags ({d} unique):\n", .{tag_counts.count()});
            var it = tag_counts.iterator();
            while (it.next()) |entry| {
                try w.print("  #{s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        if (self.entries.items.len > 0) {
            const oldest = self.entries.items[0].timestamp;
            const newest = self.entries.items[self.entries.items.len - 1].timestamp;
            try w.print("\nOldest: {d}\n", .{oldest});
            try w.print("Newest: {d}\n", .{newest});
        }

        try w.print("\nStorage: {s}", .{self.file_path});

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Clear all memories and delete the storage file.
    pub fn clear(self: *MemoryCortex) void {
        for (self.entries.items) |entry| freeEntry(self.allocator, entry);
        self.entries.clearRetainingCapacity();
        std.fs.cwd().deleteFile(self.file_path) catch {};
    }

    /// Delete a specific memory by ID. Returns true if found and deleted.
    pub fn delete(self: *MemoryCortex, id: u64) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.id == id) {
                freeEntry(self.allocator, entry);
                _ = self.entries.orderedRemove(i);
                self.save();
                return true;
            }
        }
        return false;
    }

    // ── Persistence ───────────────────────────────────────────────

    fn save(self: *MemoryCortex) void {
        const saved_entries = self.allocator.alloc(SavedEntry, self.entries.items.len) catch return;
        defer self.allocator.free(saved_entries);

        for (self.entries.items, 0..) |entry, i| {
            saved_entries[i] = .{
                .id = entry.id,
                .content = entry.content,
                .tags = entry.tags,
                .timestamp = entry.timestamp,
                .source = entry.source,
            };
        }

        const saved = SavedCortex{
            .version = 1,
            .entries = saved_entries,
        };

        const json = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(saved, .{ .whitespace = .indent_2 })}) catch return;
        defer self.allocator.free(json);

        std.fs.cwd().writeFile(.{ .sub_path = self.file_path, .data = json }) catch |err| {
            std.log.warn("Failed to save cortex: {s}", .{@errorName(err)});
        };
    }

    fn load(self: *MemoryCortex) void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        const parsed = std.json.parseFromSlice(SavedCortex, self.allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        for (parsed.value.entries) |entry| {
            const owned_content = self.allocator.dupe(u8, entry.content) catch continue;
            errdefer self.allocator.free(owned_content);
            const owned_source = self.allocator.dupe(u8, entry.source) catch {
                self.allocator.free(owned_content);
                continue;
            };
            errdefer self.allocator.free(owned_source);

            const tags = self.allocator.alloc([]const u8, entry.tags.len) catch {
                self.allocator.free(owned_content);
                self.allocator.free(owned_source);
                continue;
            };
            var tags_copied: usize = 0;
            errdefer {
                for (tags[0..tags_copied]) |t| self.allocator.free(t);
                self.allocator.free(tags);
            }

            var ok = true;
            for (entry.tags, 0..) |tag, i| {
                tags[i] = self.allocator.dupe(u8, tag) catch {
                    ok = false;
                    break;
                };
                tags_copied += 1;
            }
            if (!ok) {
                self.allocator.free(owned_content);
                self.allocator.free(owned_source);
                for (tags[0..tags_copied]) |t| self.allocator.free(t);
                self.allocator.free(tags);
                continue;
            }

            self.entries.append(self.allocator, .{
                .id = entry.id,
                .content = owned_content,
                .tags = tags,
                .timestamp = entry.timestamp,
                .source = owned_source,
            }) catch {
                self.allocator.free(owned_content);
                self.allocator.free(owned_source);
                for (tags[0..tags_copied]) |t| self.allocator.free(t);
                self.allocator.free(tags);
                continue;
            };

            // Track highest ID for next_id generation
            if (entry.id >= self.next_id) {
                self.next_id = entry.id + 1;
            }
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "memory cortex add and search" {
    const allocator = std.testing.allocator;

    // Use a temp path for testing
    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex.json"),
        .next_id = 1,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex.json") catch {};

    try cortex.add("Remember to deploy on Friday #deploy", "user", &.{});
    try cortex.add("Bug fix for login page #bugfix", "agent", &.{});
    try cortex.add("Meeting notes about architecture", "user", &.{"meeting"});

    try std.testing.expectEqual(@as(usize, 3), cortex.entries.items.len);

    // Search by content
    const results = try cortex.search("deploy");
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "deploy") != null);

    // Search by tag
    const tag_results = try cortex.search("bugfix");
    defer allocator.free(tag_results);
    try std.testing.expectEqual(@as(usize, 1), tag_results.len);

    // Search case-insensitive
    const ci_results = try cortex.search("MEETING");
    defer allocator.free(ci_results);
    try std.testing.expectEqual(@as(usize, 1), ci_results.len);
}

test "memory cortex delete" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_del.json"),
        .next_id = 1,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_del.json") catch {};

    try cortex.add("first memory", "user", &.{});
    try cortex.add("second memory", "user", &.{});

    const id = cortex.entries.items[0].id;
    try std.testing.expect(cortex.delete(id));
    try std.testing.expectEqual(@as(usize, 1), cortex.entries.items.len);
    try std.testing.expectEqualStrings("second memory", cortex.entries.items[0].content);
}

test "memory cortex clear" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_clear.json"),
        .next_id = 1,
    };
    defer cortex.deinit();

    try cortex.add("some memory", "user", &.{});
    try std.testing.expectEqual(@as(usize, 1), cortex.entries.items.len);

    cortex.clear();
    try std.testing.expectEqual(@as(usize, 0), cortex.entries.items.len);
}

test "memory cortex stats" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_stats.json"),
        .next_id = 1,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_stats.json") catch {};

    try cortex.add("user note #work", "user", &.{});
    try cortex.add("agent note #work", "agent", &.{});

    const result = try cortex.stats();
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Total memories: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "From user: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "From agent: 1") != null);
}

test "memory cortex persistence" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test_cortex_persist.json";

    // Create and populate
    {
        var cortex = MemoryCortex{
            .allocator = allocator,
            .entries = .empty,
            .file_path = try allocator.dupe(u8, path),
            .next_id = 1,
        };
        defer cortex.deinit();

        try cortex.add("persistent memory #important", "user", &.{});
        try cortex.add("another one", "agent", &.{"test"});
    }

    // Reload and verify
    {
        var cortex = MemoryCortex{
            .allocator = allocator,
            .entries = .empty,
            .file_path = try allocator.dupe(u8, path),
            .next_id = 100,
        };
        defer cortex.deinit();
        defer std.fs.cwd().deleteFile(path) catch {};

        cortex.load();

        try std.testing.expectEqual(@as(usize, 2), cortex.entries.items.len);
        try std.testing.expectEqualStrings("persistent memory #important", cortex.entries.items[0].content);
        try std.testing.expectEqualStrings("user", cortex.entries.items[0].source);
        try std.testing.expectEqual(@as(usize, 1), cortex.entries.items[0].tags.len);
        try std.testing.expectEqualStrings("important", cortex.entries.items[0].tags[0]);
    }
}
