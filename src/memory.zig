//! Memory module - Conversation history and context persistence
const std = @import("std");

/// A single message in a conversation
pub const Message = struct {
    role: []const u8, // "user" or "assistant"
    content: []const u8,
    timestamp: i64,
    agent_id: ?[]const u8, // Which agent processed this
    metadata: ?[]const u8, // Optional JSON metadata
};

/// Conversation for a specific chat/user
pub const Conversation = struct {
    chat_id: i64,
    user_id: i64,
    messages: []Message,
    created_at: i64,
    updated_at: i64,
    message_count: usize,
    total_tokens: usize, // Approximate token count

    pub fn init(allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !Conversation {
        const now = std.time.timestamp();
        return Conversation{
            .chat_id = chat_id,
            .user_id = user_id,
            .messages = try allocator.alloc(Message, 0),
            .created_at = now,
            .updated_at = now,
            .message_count = 0,
            .total_tokens = 0,
        };
    }

    pub fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages) |msg| {
            allocator.free(msg.role);
            allocator.free(msg.content);
            if (msg.agent_id) |id| allocator.free(id);
            if (msg.metadata) |meta| allocator.free(meta);
        }
        allocator.free(self.messages);
    }

    /// Add a message to the conversation
    pub fn addMessage(
        self: *Conversation,
        allocator: std.mem.Allocator,
        role: []const u8,
        content: []const u8,
        agent_id: ?[]const u8,
    ) !void {
        // Resize array
        const new_messages = try allocator.realloc(self.messages, self.message_count + 1);
        self.messages = new_messages;

        // Create message
        self.messages[self.message_count] = Message{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
            .agent_id = if (agent_id) |id| try allocator.dupe(u8, id) else null,
            .metadata = null,
        };

        self.message_count += 1;
        self.updated_at = std.time.timestamp();

        // Rough token estimation (4 chars ≈ 1 token)
        self.total_tokens += content.len / 4;
    }

    /// Get last N messages as context
    pub fn getRecentContext(self: Conversation, n: usize) []Message {
        const start = if (self.message_count > n) self.message_count - n else 0;
        return self.messages[start..self.message_count];
    }

    /// Clear all messages
    pub fn clear(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages) |msg| {
            allocator.free(msg.role);
            allocator.free(msg.content);
            if (msg.agent_id) |id| allocator.free(id);
            if (msg.metadata) |meta| allocator.free(meta);
        }
        allocator.free(self.messages);
        self.messages = allocator.alloc(Message, 0) catch return;
        self.message_count = 0;
        self.total_tokens = 0;
        self.updated_at = std.time.timestamp();
    }
};

/// Memory store for all conversations
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    conversations: std.AutoHashMap(i64, Conversation),
    max_history: usize, // Max messages per conversation
    max_context_window: usize, // Max messages to send to LLM
    persist_dir: []const u8,
    auto_persist: bool,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        persist_dir: []const u8,
        max_history: usize,
        auto_persist: bool,
    ) !Self {
        // Create persist directory if it doesn't exist
        std.fs.cwd().makePath(persist_dir) catch |err| {
            std.log.warn("Failed to create memory directory {s}: {s}", .{ persist_dir, @errorName(err) });
        };

        return Self{
            .allocator = allocator,
            .conversations = std.AutoHashMap(i64, Conversation).init(allocator),
            .max_history = max_history,
            .max_context_window = 10, // Last 10 messages as context
            .persist_dir = try allocator.dupe(u8, persist_dir),
            .auto_persist = auto_persist,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.auto_persist) {
            self.saveAll() catch |err| {
                std.log.err("Failed to save memory on shutdown: {s}", .{@errorName(err)});
            };
        }

        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.conversations.deinit();
        self.allocator.free(self.persist_dir);
    }

    /// Get or create conversation for a chat
    pub fn getOrCreateConversation(self: *Self, chat_id: i64, user_id: i64) !*Conversation {
        const result = try self.conversations.getOrPut(chat_id);
        if (!result.found_existing) {
            // Try to load from disk first
            if (try self.loadConversation(chat_id)) |loaded| {
                result.value_ptr.* = loaded;
            } else {
                result.value_ptr.* = try Conversation.init(self.allocator, chat_id, user_id);
            }
        }
        return result.value_ptr;
    }

    /// Add message to a conversation
    pub fn addMessage(
        self: *Self,
        chat_id: i64,
        user_id: i64,
        role: []const u8,
        content: []const u8,
        agent_id: ?[]const u8,
    ) !void {
        const conv = try self.getOrCreateConversation(chat_id, user_id);
        try conv.addMessage(self.allocator, role, content, agent_id);

        // Trim old messages if exceeding max_history
        if (conv.message_count > self.max_history) {
            self.trimConversation(conv);
        }

        if (self.auto_persist) {
            try self.saveConversation(chat_id);
        }
    }

    /// Get context for LLM (last N messages)
    pub fn getContext(
        self: *Self,
        chat_id: i64,
        user_id: i64,
    ) ?[]Message {
        const conv = self.conversations.get(chat_id) orelse return null;
        if (conv.user_id != user_id) return null;
        return conv.getRecentContext(self.max_context_window);
    }

    /// Clear conversation history
    pub fn clearConversation(self: *Self, chat_id: i64) !void {
        if (self.conversations.getEntry(chat_id)) |entry| {
            entry.value_ptr.clear(self.allocator);

            // Delete persisted file
            const filename = try std.fmt.allocPrint(self.allocator, "{s}/chat_{d}.json", .{
                self.persist_dir, chat_id,
            });
            defer self.allocator.free(filename);

            std.fs.cwd().deleteFile(filename) catch {};
        }
    }

    /// Trim conversation to max_history
    fn trimConversation(self: *Self, conv: *Conversation) void {
        const to_remove = conv.message_count - self.max_history;
        if (to_remove == 0) return;

        // Free old messages
        for (conv.messages[0..to_remove]) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
            if (msg.agent_id) |id| self.allocator.free(id);
            if (msg.metadata) |meta| self.allocator.free(meta);
        }

        // Shift remaining messages
        const new_len = conv.message_count - to_remove;
        for (conv.messages[to_remove..conv.message_count], 0..) |msg, i| {
            conv.messages[i] = msg;
        }

        // Resize
        conv.messages = self.allocator.realloc(conv.messages, new_len) catch return;
        conv.message_count = new_len;
    }

    /// Save all conversations to disk
    pub fn saveAll(self: *Self) !void {
        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            try self.saveConversation(entry.key_ptr.*);
        }
    }

    /// Save a specific conversation
    fn saveConversation(self: *Self, chat_id: i64) !void {
        const conv = self.conversations.get(chat_id) orelse return;

        const filename = try std.fmt.allocPrint(self.allocator, "{s}/chat_{d}.json", .{
            self.persist_dir, chat_id,
        });
        defer self.allocator.free(filename);

        // Serialize to JSON
        const json = try self.serializeConversation(conv);
        defer self.allocator.free(json);

        try std.fs.cwd().writeFile(.{
            .sub_path = filename,
            .data = json,
        });
    }

    /// Load conversation from disk
    fn loadConversation(self: *Self, chat_id: i64) !?Conversation {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/chat_{d}.json", .{
            self.persist_dir, chat_id,
        });
        defer self.allocator.free(filename);

        const content = std.fs.cwd().readFileAlloc(self.allocator, filename, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer self.allocator.free(content);

        return try self.deserializeConversation(content);
    }

    /// Serialize conversation to JSON
    fn serializeConversation(self: *Self, conv: Conversation) ![]u8 {
        // Simple JSON serialization
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        const writer = output.writer(self.allocator);

        try writer.print("{{\n", .{});
        try writer.print("  \"chat_id\": {d},\n", .{conv.chat_id});
        try writer.print("  \"user_id\": {d},\n", .{conv.user_id});
        try writer.print("  \"created_at\": {d},\n", .{conv.created_at});
        try writer.print("  \"updated_at\": {d},\n", .{conv.updated_at});
        try writer.print("  \"messages\": [\n", .{});

        for (conv.messages, 0..) |msg, i| {
            try writer.print("    {{\n", .{});
            try writer.print("      \"role\": \"{s}\",\n", .{msg.role});
            try writer.print("      \"content\": \"{s}\",\n", .{msg.content});
            try writer.print("      \"timestamp\": {d}\n", .{msg.timestamp});
            if (msg.agent_id) |id| {
                try writer.print("      ,\"agent_id\": \"{s}\"\n", .{id});
            }
            try writer.print("    }}", .{});
            if (i < conv.message_count - 1) try writer.print(",", .{});
            try writer.print("\n", .{});
        }

        try writer.print("  ]\n", .{});
        try writer.print("}}\n", .{});

        return output.toOwnedSlice(self.allocator);
    }

    /// Deserialize conversation from JSON
    fn deserializeConversation(_: *Self, _: []const u8) !Conversation {
        // For simplicity, we'll use std.json.parse
        // In production, you'd want proper JSON parsing
        return error.NotImplemented;
    }
};

/// Format messages for LLM API
pub fn formatMessagesForLLM(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    messages: []Message,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const writer = output.writer(allocator);

    if (system_prompt) |prompt| {
        try writer.print("System: {s}\n\n", .{prompt});
    }

    for (messages) |msg| {
        const role = if (std.mem.eql(u8, msg.role, "user")) "User" else "Assistant";
        try writer.print("{s}: {s}\n", .{ role, msg.content });
    }

    return output.toOwnedSlice(allocator);
}

test "MemoryStore basic operations" {
    const allocator = std.testing.allocator;

    var store = try MemoryStore.init(allocator, "./test_memory", 100, false);
    defer store.deinit();

    // Add some messages
    try store.addMessage(123456, 789012, "user", "Hello!", null);
    try store.addMessage(123456, 789012, "assistant", "Hi there!", "assistant-1");

    // Get context
    const context = store.getContext(123456, 789012);
    try std.testing.expect(context != null);
    try std.testing.expectEqual(@as(usize, 2), context.?.len);

    // Clear
    try store.clearConversation(123456);
    const empty_context = store.getContext(123456, 789012);
    try std.testing.expect(empty_context == null);
}
