//! Conversation memory: per-chat message history with persistence
const std = @import("std");

pub const OwnedMessage = struct {
    role: []const u8, // "user", "assistant", "system", "tool"
    content: ?[]const u8,
    tool_call_id: ?[]const u8, // for role="tool" results
    tool_calls_json: ?[]const u8, // raw JSON for assistant tool_calls

    pub fn deinit(self: OwnedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        if (self.content) |c| allocator.free(c);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_calls_json) |j| allocator.free(j);
    }
};

pub const Conversation = struct {
    messages: std.ArrayList(OwnedMessage),

    pub fn init() Conversation {
        return .{ .messages = .empty };
    }

    pub fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages.items) |msg| msg.deinit(allocator);
        self.messages.deinit(allocator);
    }

    /// Add a simple text message (user/assistant)
    pub fn addMessage(self: *Conversation, allocator: std.mem.Allocator, role: []const u8, content: []const u8) !void {
        try self.messages.append(allocator, .{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
            .tool_call_id = null,
            .tool_calls_json = null,
        });
    }

    /// Add an assistant message that contains tool calls (no text content)
    pub fn addToolCallMessage(self: *Conversation, allocator: std.mem.Allocator, tool_calls_json: []const u8) !void {
        try self.messages.append(allocator, .{
            .role = try allocator.dupe(u8, "assistant"),
            .content = null,
            .tool_call_id = null,
            .tool_calls_json = try allocator.dupe(u8, tool_calls_json),
        });
    }

    /// Add a tool result message
    pub fn addToolResultMessage(self: *Conversation, allocator: std.mem.Allocator, tool_call_id: []const u8, content: []const u8) !void {
        try self.messages.append(allocator, .{
            .role = try allocator.dupe(u8, "tool"),
            .content = try allocator.dupe(u8, content),
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .tool_calls_json = null,
        });
    }

    pub fn clear(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages.items) |msg| msg.deinit(allocator);
        self.messages.clearRetainingCapacity();
    }

    /// Trim to keep only last `max` messages
    pub fn trim(self: *Conversation, allocator: std.mem.Allocator, max: usize) void {
        if (self.messages.items.len <= max) return;
        const to_remove = self.messages.items.len - max;
        for (self.messages.items[0..to_remove]) |msg| msg.deinit(allocator);
        std.mem.copyForwards(
            OwnedMessage,
            self.messages.items[0..max],
            self.messages.items[to_remove..],
        );
        self.messages.shrinkRetainingCapacity(max);
    }
};

// ── Persistence ───────────────────────────────────────────────────

const SavedMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
};

const SavedConversation = struct {
    chat_id: i64,
    messages: []const SavedMessage,
};

pub fn saveConversation(allocator: std.mem.Allocator, persist_dir: []const u8, chat_id: i64, conv: *const Conversation) void {
    const msgs = allocator.alloc(SavedMessage, conv.messages.items.len) catch return;
    defer allocator.free(msgs);

    for (conv.messages.items, 0..) |msg, i| {
        msgs[i] = .{
            .role = msg.role,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls_json = msg.tool_calls_json,
        };
    }

    const saved = SavedConversation{
        .chat_id = chat_id,
        .messages = msgs,
    };

    const json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(saved, .{ .whitespace = .indent_2 })}) catch return;
    defer allocator.free(json);

    const filename = std.fmt.allocPrint(allocator, "{s}/chat_{d}.json", .{ persist_dir, chat_id }) catch return;
    defer allocator.free(filename);

    std.fs.cwd().writeFile(.{ .sub_path = filename, .data = json }) catch |err| {
        std.log.warn("Failed to save conversation: {s}", .{@errorName(err)});
    };
}

pub fn loadConversation(allocator: std.mem.Allocator, persist_dir: []const u8, chat_id: i64) ?Conversation {
    const filename = std.fmt.allocPrint(allocator, "{s}/chat_{d}.json", .{ persist_dir, chat_id }) catch return null;
    defer allocator.free(filename);

    const content = std.fs.cwd().readFileAlloc(allocator, filename, 10 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(SavedConversation, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var conv = Conversation.init();
    for (parsed.value.messages) |msg| {
        const role = allocator.dupe(u8, msg.role) catch {
            conv.deinit(allocator);
            return null;
        };
        const content_copy = if (msg.content) |c| (allocator.dupe(u8, c) catch {
            allocator.free(role);
            conv.deinit(allocator);
            return null;
        }) else null;
        const tc_id = if (msg.tool_call_id) |id| (allocator.dupe(u8, id) catch {
            allocator.free(role);
            if (content_copy) |c| allocator.free(c);
            conv.deinit(allocator);
            return null;
        }) else null;
        const tc_json = if (msg.tool_calls_json) |j| (allocator.dupe(u8, j) catch {
            allocator.free(role);
            if (content_copy) |c| allocator.free(c);
            if (tc_id) |id| allocator.free(id);
            conv.deinit(allocator);
            return null;
        }) else null;

        conv.messages.append(allocator, .{
            .role = role,
            .content = content_copy,
            .tool_call_id = tc_id,
            .tool_calls_json = tc_json,
        }) catch {
            allocator.free(role);
            if (content_copy) |c| allocator.free(c);
            if (tc_id) |id| allocator.free(id);
            if (tc_json) |j| allocator.free(j);
            conv.deinit(allocator);
            return null;
        };
    }
    return conv;
}

// ── Tests ─────────────────────────────────────────────────────────

test "conversation add and trim" {
    const allocator = std.testing.allocator;
    var conv = Conversation.init();
    defer conv.deinit(allocator);

    try conv.addMessage(allocator, "user", "hello");
    try conv.addMessage(allocator, "assistant", "hi");
    try conv.addMessage(allocator, "user", "bye");

    try std.testing.expectEqual(@as(usize, 3), conv.messages.items.len);

    conv.trim(allocator, 2);
    try std.testing.expectEqual(@as(usize, 2), conv.messages.items.len);
    try std.testing.expectEqualStrings("hi", conv.messages.items[0].content.?);
    try std.testing.expectEqualStrings("bye", conv.messages.items[1].content.?);
}

test "conversation tool messages" {
    const allocator = std.testing.allocator;
    var conv = Conversation.init();
    defer conv.deinit(allocator);

    try conv.addMessage(allocator, "user", "run ls");
    try conv.addToolCallMessage(allocator, "[{\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]");
    try conv.addToolResultMessage(allocator, "call_1", "file1.txt\nfile2.txt");

    try std.testing.expectEqual(@as(usize, 3), conv.messages.items.len);
    try std.testing.expectEqualStrings("tool", conv.messages.items[2].role);
    try std.testing.expectEqualStrings("call_1", conv.messages.items[2].tool_call_id.?);
}
