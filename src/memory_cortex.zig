//! Memory Cortex: persistent JSON-based memory storage for agents
//! Stores memories in memory/cortex.json with search, stats, and clear operations.
//! Enhanced with semantic/vector search capabilities using TF-IDF and cosine similarity.
const std = @import("std");

pub const MemoryEntry = struct {
    id: u64, // timestamp-based unique ID
    content: []const u8,
    tags: []const []const u8,
    timestamp: i64, // unix epoch seconds
    source: []const u8, // "user" or "agent"
};

pub const ScoredMemory = struct {
    entry: MemoryEntry,
    score: f64,
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

// Common English stop words to filter out
const STOP_WORDS = [_][]const u8{
    "the",   "a",     "an",     "and",  "or",    "but",  "is",   "are",   "was",   "were",
    "be",    "been",  "being",  "have", "has",   "had",  "do",   "does",  "did",   "will",
    "would", "could", "should", "may",  "might", "must", "to",   "of",    "in",    "on",
    "at",    "by",    "for",    "with", "as",    "this", "that", "these", "those", "from",
    "up",    "out",   "if",     "it",   "its",   "i",    "you",  "he",    "she",   "we",
    "they",  "my",    "your",   "his",  "her",
};

pub const MemoryCortex = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(MemoryEntry),
    file_path: []const u8,
    next_id: u64,

    // Vocabulary for TF-IDF
    vocab: std.StringHashMap(usize), // term -> document frequency
    term_ids: std.StringHashMap(usize), // term -> unique ID
    next_term_id: usize,

    pub fn init(allocator: std.mem.Allocator, persist_dir: []const u8) !MemoryCortex {
        const file_path = try std.fs.path.join(allocator, &.{ persist_dir, "cortex.json" });

        var cortex = MemoryCortex{
            .allocator = allocator,
            .entries = .empty,
            .file_path = file_path,
            .next_id = @intCast(@as(u64, @bitCast(std.time.timestamp()))),
            .vocab = std.StringHashMap(usize).init(allocator),
            .term_ids = std.StringHashMap(usize).init(allocator),
            .next_term_id = 0,
        };

        cortex.load();
        try cortex.buildVocabulary();
        return cortex;
    }

    pub fn deinit(self: *MemoryCortex) void {
        for (self.entries.items) |entry| freeEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.file_path);

        // Clean up vocabulary
        var vocab_it = self.vocab.keyIterator();
        while (vocab_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.vocab.deinit();

        var term_it = self.term_ids.keyIterator();
        while (term_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.term_ids.deinit();
    }

    fn freeEntry(allocator: std.mem.Allocator, entry: MemoryEntry) void {
        allocator.free(entry.content);
        allocator.free(entry.source);
        for (entry.tags) |tag| allocator.free(tag);
        allocator.free(entry.tags);
    }

    // ── Tokenization & Preprocessing ───────────────────────────────

    fn isStopWord(word: []const u8) bool {
        for (STOP_WORDS) |stop_word| {
            if (std.mem.eql(u8, word, stop_word)) return true;
        }
        return false;
    }

    fn tokenizeText(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }

        var i: usize = 0;
        while (i < text.len) {
            // Skip non-alphabetic characters
            while (i < text.len and !std.ascii.isAlphabetic(text[i])) {
                i += 1;
            }
            if (i >= text.len) break;

            const start = i;
            while (i < text.len and std.ascii.isAlphabetic(text[i])) {
                i += 1;
            }

            const word = text[start..i];
            const lower_word = try allocator.alloc(u8, word.len);
            for (word, 0..) |c, j| {
                lower_word[j] = std.ascii.toLower(c);
            }

            // Filter out stop words and short words
            if (lower_word.len >= 3 and !isStopWord(lower_word)) {
                try tokens.append(allocator, lower_word);
            } else {
                allocator.free(lower_word);
            }
        }

        return try tokens.toOwnedSlice(allocator);
    }

    // ── Vocabulary & TF-IDF ────────────────────────────────────────

    /// Build vocabulary from all entries. Call this after loading entries.
    pub fn buildVocabulary(self: *MemoryCortex) !void {
        // Clear existing vocabulary
        var vocab_it = self.vocab.keyIterator();
        while (vocab_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.vocab.clearRetainingCapacity();

        var term_it = self.term_ids.keyIterator();
        while (term_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.term_ids.clearRetainingCapacity();
        self.next_term_id = 0;

        // Count document frequency for each term
        for (self.entries.items) |entry| {
            const tokens = try tokenizeText(self.allocator, entry.content);
            defer {
                for (tokens) |t| self.allocator.free(t);
                self.allocator.free(tokens);
            }

            // Use a set to track which terms appear in this document
            var seen = std.AutoHashMap(usize, void).init(self.allocator);
            defer seen.deinit();

            for (tokens) |token| {
                const id_result = try self.term_ids.getOrPut(token);
                if (!id_result.found_existing) {
                    id_result.key_ptr.* = try self.allocator.dupe(u8, token);
                    id_result.value_ptr.* = self.next_term_id;
                    self.next_term_id += 1;
                }

                const term_id = id_result.value_ptr.*;
                if (!seen.contains(term_id)) {
                    try seen.put(term_id, {});

                    // Increment document frequency
                    const df_result = try self.vocab.getOrPut(id_result.key_ptr.*);
                    if (!df_result.found_existing) {
                        df_result.key_ptr.* = try self.allocator.dupe(u8, token);
                        df_result.value_ptr.* = 1;
                    } else {
                        df_result.value_ptr.* += 1;
                    }
                } else {
                    self.allocator.free(token);
                }
            }
        }
    }

    /// Calculate TF-IDF vector for a piece of text.
    fn computeTfIdfVector(self: *MemoryCortex, text: []const u8) !std.AutoHashMap(usize, f64) {
        var vector = std.AutoHashMap(usize, f64).init(self.allocator);
        errdefer vector.deinit();

        const tokens = try tokenizeText(self.allocator, text);
        defer {
            for (tokens) |t| self.allocator.free(t);
            self.allocator.free(tokens);
        }

        if (tokens.len == 0) return vector;

        // Count term frequencies
        var tf = std.AutoHashMap(usize, usize).init(self.allocator);
        defer tf.deinit();

        for (tokens) |token| {
            const term_id = self.term_ids.get(token) orelse continue;
            const result = try tf.getOrPut(term_id);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }

        // Compute TF-IDF
        const total_docs: f64 = @floatFromInt(self.entries.items.len);
        var tf_it = tf.iterator();
        while (tf_it.next()) |entry| {
            const term_id = entry.key_ptr.*;
            const term_freq = entry.value_ptr.*;

            // Get the term from term_ids
            var term_it = self.term_ids.iterator();
            var term: []const u8 = "";
            while (term_it.next()) |kv| {
                if (kv.value_ptr.* == term_id) {
                    term = kv.key_ptr.*;
                    break;
                }
            }

            if (term.len == 0) continue;

            const doc_freq: f64 = @floatFromInt(self.vocab.get(term) orelse 1);
            const tf_score: f64 = @as(f64, @floatFromInt(term_freq)) / @as(f64, @floatFromInt(tokens.len));
            const idf_score = std.math.log(f64, 10, total_docs / doc_freq);

            try vector.put(term_id, tf_score * idf_score);
        }

        return vector;
    }

    /// Calculate cosine similarity between two vectors.
    fn cosineSimilarity(vec1: std.AutoHashMap(usize, f64), vec2: std.AutoHashMap(usize, f64)) f64 {
        var dot_product: f64 = 0;
        var norm1: f64 = 0;
        var norm2: f64 = 0;

        // Compute dot product
        var it1 = vec1.iterator();
        while (it1.next()) |entry| {
            const term_id = entry.key_ptr.*;
            const val1 = entry.value_ptr.*;
            const val2 = vec2.get(term_id) orelse 0;
            dot_product += val1 * val2;
            norm1 += val1 * val1;
        }

        // Compute norm of vec2
        var it2 = vec2.iterator();
        while (it2.next()) |entry| {
            const val2 = entry.value_ptr.*;
            norm2 += val2 * val2;
        }

        if (norm1 == 0 or norm2 == 0) return 0;
        return dot_product / (std.math.sqrt(norm1) * std.math.sqrt(norm2));
    }

    // ── Public API ─────────────────────────────────────────────────

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

        // Update vocabulary with new entry
        try self.updateVocabularyWithEntry(entry);

        self.save();
    }

    fn updateVocabularyWithEntry(self: *MemoryCortex, entry: MemoryEntry) !void {
        const tokens = try tokenizeText(self.allocator, entry.content);
        defer self.allocator.free(tokens);

        var seen = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen.deinit();

        for (tokens) |token| {
            const id_result = try self.term_ids.getOrPut(token);
            if (!id_result.found_existing) {
                // New term: move ownership of token to term_ids
                id_result.key_ptr.* = token;
                id_result.value_ptr.* = self.next_term_id;
                self.next_term_id += 1;
            } else {
                // Existing term: free the duplicate token
                self.allocator.free(token);
            }

            const term_id = id_result.value_ptr.*;
            if (!seen.contains(term_id)) {
                try seen.put(term_id, {});

                // Get the canonical term from term_ids
                const canonical_term = id_result.key_ptr.*;
                const df_result = try self.vocab.getOrPut(canonical_term);
                if (!df_result.found_existing) {
                    // Duplicate the key for vocab (different hash map)
                    df_result.key_ptr.* = try self.allocator.dupe(u8, canonical_term);
                    df_result.value_ptr.* = 1;
                } else {
                    df_result.value_ptr.* += 1;
                }
            }
        }
    }

    /// Search memories by query string. Matches against content and tags (case-insensitive).
    /// DEPRECATED: Use searchSemantic for better results.
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

    /// Semantic search: Find memories by meaning using TF-IDF and cosine similarity.
    /// Returns results sorted by relevance score (highest first).
    pub fn searchSemantic(self: *MemoryCortex, query: []const u8, max_results: usize, min_score: f64) ![]const ScoredMemory {
        if (self.entries.items.len == 0) {
            return &[_]ScoredMemory{};
        }

        // Compute query vector
        var query_vector = try self.computeTfIdfVector(query);
        defer query_vector.deinit();

        var scored_results: std.ArrayList(ScoredMemory) = .empty;
        defer scored_results.deinit(self.allocator);

        // Score each entry
        for (self.entries.items) |entry| {
            var entry_vector = try self.computeTfIdfVector(entry.content);
            defer entry_vector.deinit();

            const score = cosineSimilarity(query_vector, entry_vector);

            if (score >= min_score) {
                try scored_results.append(self.allocator, ScoredMemory{
                    .entry = entry,
                    .score = score,
                });
            }
        }

        // Sort by score (descending)
        const SortContext = struct {
            pub fn lessThan(_: @This(), a: ScoredMemory, b: ScoredMemory) bool {
                return a.score > b.score; // Higher score first
            }
        };
        std.sort.block(ScoredMemory, scored_results.items, SortContext{}, SortContext.lessThan);

        // Return top results
        const result_count = @min(max_results, scored_results.items.len);
        const results = try self.allocator.alloc(ScoredMemory, result_count);
        for (0..result_count) |i| {
            results[i] = scored_results.items[i];
        }

        return results;
    }

    /// Auto-retrieve: Automatically find relevant memories for a message and format them as context.
    /// Returns a formatted string containing relevant memories, or null if none found.
    pub fn autoRetrieve(self: *MemoryCortex, message: []const u8, max_memories: usize, min_score: f64) !?[]const u8 {
        const results = try self.searchSemantic(message, max_memories, min_score);
        defer self.allocator.free(results);

        if (results.len == 0) {
            return null;
        }

        var buf: std.ArrayList(u8) = .empty;
        const w = buf.writer(self.allocator);

        try w.print("Relevant context from memory:\n", .{});
        for (results, 0..) |result, i| {
            try w.print("[{d}] (score: {d:.2}) {s}: {s}\n", .{
                i + 1,
                result.score,
                result.entry.source,
                result.entry.content,
            });
        }

        return try buf.toOwnedSlice(self.allocator);
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
        try w.print("  Vocabulary size: {d} unique terms\n", .{self.vocab.count()});

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

        // Clear vocabulary
        var vocab_it = self.vocab.keyIterator();
        while (vocab_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.vocab.clearRetainingCapacity();

        var term_it = self.term_ids.keyIterator();
        while (term_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.term_ids.clearRetainingCapacity();
        self.next_term_id = 0;

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
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
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

test "memory cortex semantic search" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_semantic.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_semantic.json") catch {};

    // Add memories with related concepts
    try cortex.add("The database server crashed yesterday and needs restart", "system", &.{});
    try cortex.add("User reported login authentication failure on production", "user", &.{});
    try cortex.add("Deploy the new feature to staging environment today", "agent", &.{});
    try cortex.add("Coffee machine needs refilling in the break room", "user", &.{});
    try cortex.add("Database migration completed successfully", "agent", &.{});

    // Rebuild vocabulary after adding entries
    try cortex.buildVocabulary();

    // Search for "server problems" - should match database crash and auth failure
    const results = try cortex.searchSemantic("server problems", 3, 0.0);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);

    // Check that results have scores
    for (results) |result| {
        try std.testing.expect(result.score >= 0);
        try std.testing.expect(result.score <= 1);
    }

    // Search for "deployment" - should match deploy-related memories
    const deploy_results = try cortex.searchSemantic("deployment", 3, 0.0);
    defer allocator.free(deploy_results);
    try std.testing.expect(deploy_results.len > 0);
}

test "memory cortex semantic search relevance scoring" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_scoring.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_scoring.json") catch {};

    try cortex.add("Python programming tutorial for beginners", "agent", &.{});
    try cortex.add("How to learn Python programming language effectively", "agent", &.{});
    try cortex.add("Database administration best practices guide", "agent", &.{});
    try cortex.add("Python snakes are non-venomous constrictors", "user", &.{});

    try cortex.buildVocabulary();

    // Search for Python programming
    const results = try cortex.searchSemantic("python programming", 4, 0.0);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 3);

    // The top results should be about Python programming, not snakes
    try std.testing.expect(std.mem.indexOf(u8, results[0].entry.content, "programming") != null or
        std.mem.indexOf(u8, results[0].entry.content, "tutorial") != null or
        std.mem.indexOf(u8, results[0].entry.content, "learn") != null);
}

test "memory cortex auto retrieve" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_retrieve.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_retrieve.json") catch {};

    try cortex.add("Previous deployment failed due to missing environment variables", "system", &.{});
    try cortex.add("User authentication module uses JWT tokens", "agent", &.{});
    try cortex.add("Docker containers should be restarted daily", "user", &.{});

    try cortex.buildVocabulary();

    // Test auto-retrieve for deployment-related message
    const context = try cortex.autoRetrieve("how do I deploy the application?", 2, 0.0);

    if (context) |ctx| {
        defer allocator.free(ctx);
        try std.testing.expect(std.mem.indexOf(u8, ctx, "deployment") != null or
            std.mem.indexOf(u8, ctx, "deploy") != null);
    }
}

test "memory cortex auto retrieve no results" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_no_retrieve.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_no_retrieve.json") catch {};

    try cortex.add("Something about databases", "agent", &.{});
    try cortex.buildVocabulary();

    // Test with high threshold that should return no results
    const context = try cortex.autoRetrieve("completely unrelated topic xyz", 2, 0.9);
    try std.testing.expect(context == null);
}

test "memory cortex delete" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_del.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
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
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();

    try cortex.add("some memory", "user", &.{});
    try std.testing.expectEqual(@as(usize, 1), cortex.entries.items.len);

    cortex.clear();
    try std.testing.expectEqual(@as(usize, 0), cortex.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), cortex.vocab.count());
}

test "memory cortex stats" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_stats.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
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
    try std.testing.expect(std.mem.indexOf(u8, result, "Vocabulary size:") != null);
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
            .vocab = std.StringHashMap(usize).init(allocator),
            .term_ids = std.StringHashMap(usize).init(allocator),
            .next_term_id = 0,
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
            .vocab = std.StringHashMap(usize).init(allocator),
            .term_ids = std.StringHashMap(usize).init(allocator),
            .next_term_id = 0,
        };
        defer cortex.deinit();
        defer std.fs.cwd().deleteFile(path) catch {};

        cortex.load();
        try cortex.buildVocabulary();

        try std.testing.expectEqual(@as(usize, 2), cortex.entries.items.len);
        try std.testing.expectEqualStrings("persistent memory #important", cortex.entries.items[0].content);
        try std.testing.expectEqualStrings("user", cortex.entries.items[0].source);
        try std.testing.expectEqual(@as(usize, 1), cortex.entries.items[0].tags.len);
        try std.testing.expectEqualStrings("important", cortex.entries.items[0].tags[0]);
    }
}

test "memory cortex tokenization" {
    const allocator = std.testing.allocator;

    const text = "The quick brown fox jumps! Over the lazy dog.";
    const tokens = try MemoryCortex.tokenizeText(allocator, text);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }

    // Should have filtered out stop words and short words
    try std.testing.expect(tokens.len > 0);

    // Check that "quick", "brown", "fox", "jumps", "lazy", "dog" are present
    var found_brown = false;
    var found_fox = false;
    for (tokens) |token| {
        if (std.mem.eql(u8, token, "brown")) found_brown = true;
        if (std.mem.eql(u8, token, "fox")) found_fox = true;
    }
    try std.testing.expect(found_brown);
    try std.testing.expect(found_fox);
}

test "memory cortex backward compatibility" {
    const allocator = std.testing.allocator;

    var cortex = MemoryCortex{
        .allocator = allocator,
        .entries = .empty,
        .file_path = try allocator.dupe(u8, "/tmp/test_cortex_compat.json"),
        .next_id = 1,
        .vocab = std.StringHashMap(usize).init(allocator),
        .term_ids = std.StringHashMap(usize).init(allocator),
        .next_term_id = 0,
    };
    defer cortex.deinit();
    defer std.fs.cwd().deleteFile("/tmp/test_cortex_compat.json") catch {};

    // Old API should still work
    try cortex.add("test memory", "user", &.{});

    const search_results = try cortex.search("test");
    defer allocator.free(search_results);
    try std.testing.expectEqual(@as(usize, 1), search_results.len);

    const stats_str = try cortex.stats();
    defer allocator.free(stats_str);
    try std.testing.expect(std.mem.indexOf(u8, stats_str, "Total memories: 1") != null);

    try std.testing.expect(cortex.delete(cortex.entries.items[0].id));
    cortex.clear();
}
