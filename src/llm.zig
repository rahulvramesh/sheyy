//! OpenAI-compatible and Anthropic-compatible LLM API client
//! Supports both plain text completions and tool-calling (function calling).
const std = @import("std");

pub const LlmError = error{
    HttpRequestFailed,
    InvalidResponse,
    JsonParseError,
    OutOfMemory,
    ApiError,
};

/// API format types
pub const ApiFormat = enum {
    openai,
    anthropic,
};

/// A simple chat message (backward-compatible)
pub const ChatMessage = struct {
    role: []const u8, // "system", "user", "assistant"
    content: []const u8,
};

/// A rich chat message that supports tool-calling
pub const RichMessage = struct {
    role: []const u8, // "system", "user", "assistant", "tool"
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null, // for role="tool" results
    tool_calls_json: ?[]const u8 = null, // raw JSON for assistant tool_calls to echo back
};

/// A tool call parsed from the LLM response
pub const ToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments_json: []const u8,
};

/// Rich LLM response: either text content or tool calls (or both)
pub const LlmResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    raw_tool_calls_json: ?[]const u8 = null, // original JSON to echo back in next request

    pub fn deinit(self: LlmResponse, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| {
                allocator.free(call.id);
                allocator.free(call.function_name);
                allocator.free(call.arguments_json);
            }
            allocator.free(calls);
        }
        if (self.raw_tool_calls_json) |j| allocator.free(j);
    }

    pub fn hasToolCalls(self: LlmResponse) bool {
        return self.tool_calls != null and self.tool_calls.?.len > 0;
    }
};

/// LLM client for interacting with OpenAI-compatible and Anthropic-compatible APIs
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    endpoint_url: []const u8,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, endpoint_url: []const u8) Self {
        return Self{
            .allocator = allocator,
            .api_key = api_key,
            .endpoint_url = endpoint_url,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    /// Simple text-only completion (backward-compatible)
    pub fn chatCompletion(
        self: *Self,
        messages: []const ChatMessage,
        model_name: []const u8,
        temperature: f32,
        api_format: ApiFormat,
    ) LlmError![]u8 {
        // Convert simple messages to rich messages
        const rich = self.allocator.alloc(RichMessage, messages.len) catch return LlmError.OutOfMemory;
        defer self.allocator.free(rich);
        for (messages, 0..) |msg, i| {
            rich[i] = .{ .role = msg.role, .content = msg.content };
        }

        const response = try self.chatCompletionWithTools(rich, model_name, temperature, api_format, null);
        defer {
            // Free tool_calls and raw json if any, we only want content
            if (response.tool_calls) |calls| {
                for (calls) |call| {
                    self.allocator.free(call.id);
                    self.allocator.free(call.function_name);
                    self.allocator.free(call.arguments_json);
                }
                self.allocator.free(calls);
            }
            if (response.raw_tool_calls_json) |j| self.allocator.free(j);
        }

        if (response.content) |c| {
            const result = self.allocator.dupe(u8, c) catch return LlmError.OutOfMemory;
            return result;
        }
        return LlmError.InvalidResponse;
    }

    /// Full completion with tool-calling support
    pub fn chatCompletionWithTools(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        api_format: ApiFormat,
        tools_json: ?[]const u8, // pre-serialized tools array, or null
    ) LlmError!LlmResponse {
        return switch (api_format) {
            .openai => self.completionOpenAIRich(messages, model_name, temperature, tools_json),
            .anthropic => self.completionAnthropicRich(messages, model_name, temperature, tools_json),
        };
    }

    // ── OpenAI Format ─────────────────────────────────────────────

    fn completionOpenAIRich(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        tools_json: ?[]const u8,
    ) LlmError!LlmResponse {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"temperature\":{d:.2},\"messages\":[", .{ model_name, temperature });

        for (messages, 0..) |msg, i| {
            if (i > 0) try w.print(",", .{});
            try self.writeOpenAIMessage(w, msg);
        }
        try w.print("]", .{});

        // Add tools if provided
        if (tools_json) |tj| {
            try w.print(",\"tools\":{s}", .{tj});
        }

        try w.print("}}", .{});

        const response = try self.doHttpRequest(payload_buf.items, .openai);
        return self.parseOpenAIRichResponse(response);
    }

    fn writeOpenAIMessage(self: *Self, w: anytype, msg: RichMessage) !void {
        _ = self;
        if (std.mem.eql(u8, msg.role, "tool")) {
            // Tool result message
            try w.print("{{\"role\":\"tool\",\"tool_call_id\":\"{s}\",\"content\":{f}}}", .{
                msg.tool_call_id orelse "unknown",
                std.json.fmt(msg.content orelse "", .{}),
            });
        } else if (msg.tool_calls_json != null) {
            // Assistant message with tool calls
            try w.print("{{\"role\":\"assistant\",\"tool_calls\":{s}", .{msg.tool_calls_json.?});
            if (msg.content) |c| {
                try w.print(",\"content\":{f}", .{std.json.fmt(c, .{})});
            }
            try w.print("}}", .{});
        } else {
            // Regular text message
            try w.print("{{\"role\":\"{s}\",\"content\":{f}}}", .{
                msg.role,
                std.json.fmt(msg.content orelse "", .{}),
            });
        }
    }

    fn parseOpenAIRichResponse(self: *Self, response: []const u8) LlmError!LlmResponse {
        // Parse to check for tool_calls
        const OaiFunc = struct { name: []const u8, arguments: []const u8 };
        const OaiToolCall = struct { id: []const u8, function: OaiFunc };
        const OaiMessage = struct {
            content: ?[]const u8 = null,
            tool_calls: ?[]OaiToolCall = null,
        };
        const OaiChoice = struct { message: OaiMessage };
        const OaiResp = struct { choices: []OaiChoice };

        const parsed = std.json.parseFromSlice(OaiResp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.log.err("Failed to parse OpenAI response: {s}", .{response});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) return LlmError.InvalidResponse;
        const msg = parsed.value.choices[0].message;

        var result: LlmResponse = .{};

        // Extract text content
        if (msg.content) |c| {
            result.content = self.allocator.dupe(u8, c) catch return LlmError.OutOfMemory;
        }

        // Extract tool calls
        if (msg.tool_calls) |calls| {
            if (calls.len > 0) {
                var tool_calls = self.allocator.alloc(ToolCall, calls.len) catch return LlmError.OutOfMemory;
                errdefer self.allocator.free(tool_calls);

                for (calls, 0..) |call, idx| {
                    tool_calls[idx] = .{
                        .id = self.allocator.dupe(u8, call.id) catch return LlmError.OutOfMemory,
                        .function_name = self.allocator.dupe(u8, call.function.name) catch return LlmError.OutOfMemory,
                        .arguments_json = self.allocator.dupe(u8, call.function.arguments) catch return LlmError.OutOfMemory,
                    };
                }
                result.tool_calls = tool_calls;

                // Serialize the raw tool_calls JSON to echo back in next request
                result.raw_tool_calls_json = self.serializeToolCallsJson(calls) catch return LlmError.OutOfMemory;
            }
        }

        return result;
    }

    fn serializeToolCallsJson(self: *Self, calls: anytype) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("[", .{});
        for (calls, 0..) |call, i| {
            if (i > 0) try w.print(",", .{});
            try w.print(
                \\{{"id":"{s}","type":"function","function":{{"name":"{s}","arguments":{f}}}}}
            , .{ call.id, call.function.name, std.json.fmt(call.function.arguments, .{}) });
        }
        try w.print("]", .{});

        return try self.allocator.dupe(u8, buf.items);
    }

    // ── Anthropic Format ──────────────────────────────────────────

    fn completionAnthropicRich(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        tools_json: ?[]const u8,
    ) LlmError!LlmResponse {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"max_tokens\":4096,\"temperature\":{d:.2}", .{ model_name, temperature });

        // Extract system message
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                if (msg.content) |c| {
                    try w.print(",\"system\":{f}", .{std.json.fmt(c, .{})});
                }
                break;
            }
        }

        // Add tools
        if (tools_json) |tj| {
            try w.print(",\"tools\":{s}", .{tj});
        }

        // Non-system messages
        try w.print(",\"messages\":[", .{});
        var first = true;
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) continue;
            if (!first) try w.print(",", .{});
            first = false;
            try self.writeAnthropicMessage(w, msg);
        }
        try w.print("]}}", .{});

        const response = try self.doHttpRequest(payload_buf.items, .anthropic);
        return self.parseAnthropicRichResponse(response);
    }

    fn writeAnthropicMessage(self: *Self, w: anytype, msg: RichMessage) !void {
        _ = self;
        if (std.mem.eql(u8, msg.role, "tool")) {
            // Tool result in Anthropic format
            try w.print("{{\"role\":\"user\",\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":{f}}}]}}", .{
                msg.tool_call_id orelse "unknown",
                std.json.fmt(msg.content orelse "", .{}),
            });
        } else if (msg.tool_calls_json != null) {
            // Assistant message with tool_use blocks
            try w.print("{{\"role\":\"assistant\",\"content\":{s}}}", .{msg.tool_calls_json.?});
        } else {
            try w.print("{{\"role\":\"{s}\",\"content\":{f}}}", .{
                msg.role,
                std.json.fmt(msg.content orelse "", .{}),
            });
        }
    }

    fn parseAnthropicRichResponse(self: *Self, response: []const u8) LlmError!LlmResponse {
        const Block = struct {
            type: ?[]const u8 = null,
            text: ?[]const u8 = null,
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            input: ?std.json.Value = null,
        };
        const Resp = struct { content: []Block };

        const parsed = std.json.parseFromSlice(Resp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.log.err("Failed to parse Anthropic response: {s}", .{response});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.content.len == 0) return LlmError.InvalidResponse;

        var result: LlmResponse = .{};

        // Collect text blocks and tool_use blocks
        var tool_calls_list: std.ArrayList(ToolCall) = .empty;
        defer tool_calls_list.deinit(self.allocator);

        for (parsed.value.content) |block| {
            const block_type = block.type orelse "text";
            if (std.mem.eql(u8, block_type, "text")) {
                if (block.text) |t| {
                    result.content = self.allocator.dupe(u8, t) catch return LlmError.OutOfMemory;
                }
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                const id = block.id orelse continue;
                const name = block.name orelse continue;
                const input_val = block.input orelse continue;

                // Serialize input back to JSON string
                const args_json = std.fmt.allocPrint(self.allocator, "{f}", .{
                    std.json.fmt(input_val, .{}),
                }) catch return LlmError.OutOfMemory;

                try tool_calls_list.append(self.allocator, .{
                    .id = self.allocator.dupe(u8, id) catch return LlmError.OutOfMemory,
                    .function_name = self.allocator.dupe(u8, name) catch return LlmError.OutOfMemory,
                    .arguments_json = args_json,
                });
            }
        }

        if (tool_calls_list.items.len > 0) {
            result.tool_calls = tool_calls_list.toOwnedSlice(self.allocator) catch return LlmError.OutOfMemory;

            // Build raw_tool_calls_json for Anthropic (content array with tool_use blocks)
            result.raw_tool_calls_json = self.serializeAnthropicToolCallsJson(parsed.value.content) catch return LlmError.OutOfMemory;
        }

        return result;
    }

    fn serializeAnthropicToolCallsJson(self: *Self, content: anytype) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("[", .{});
        var first = true;
        for (content) |block| {
            const block_type = block.type orelse continue;
            if (!first) try w.print(",", .{});
            first = false;
            if (std.mem.eql(u8, block_type, "text")) {
                if (block.text) |t| {
                    try w.print("{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(t, .{})});
                }
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                try w.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{f}}}", .{
                    block.id orelse "",
                    block.name orelse "",
                    std.json.fmt(block.input orelse .null, .{}),
                });
            }
        }
        try w.print("]", .{});

        return try self.allocator.dupe(u8, buf.items);
    }

    // ── HTTP Helper ───────────────────────────────────────────────

    fn doHttpRequest(self: *Self, json_payload: []const u8, api_format: ApiFormat) LlmError![]const u8 {
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_writer.deinit();

        switch (api_format) {
            .openai => {
                const auth_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch {
                    return LlmError.OutOfMemory;
                };
                defer self.allocator.free(auth_header);

                const fetch_result = self.http_client.fetch(.{
                    .location = .{ .url = self.endpoint_url },
                    .method = .POST,
                    .headers = .{
                        .authorization = .{ .override = auth_header },
                        .content_type = .{ .override = "application/json" },
                    },
                    .payload = json_payload,
                    .response_writer = &response_writer.writer,
                }) catch |err| {
                    std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                    return LlmError.HttpRequestFailed;
                };

                const response = response_writer.written();
                if (fetch_result.status != .ok) {
                    std.log.err("LLM API error {d}: {s}", .{ @intFromEnum(fetch_result.status), response });
                    return LlmError.ApiError;
                }
                return response;
            },
            .anthropic => {
                const extra_headers = self.allocator.alloc(std.http.Header, 1) catch return LlmError.OutOfMemory;
                defer self.allocator.free(extra_headers);
                extra_headers[0] = .{ .name = "x-api-key", .value = self.api_key };

                const fetch_result = self.http_client.fetch(.{
                    .location = .{ .url = self.endpoint_url },
                    .method = .POST,
                    .headers = .{
                        .content_type = .{ .override = "application/json" },
                    },
                    .extra_headers = extra_headers,
                    .payload = json_payload,
                    .response_writer = &response_writer.writer,
                }) catch |err| {
                    std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                    return LlmError.HttpRequestFailed;
                };

                const response = response_writer.written();
                if (fetch_result.status != .ok) {
                    std.log.err("Anthropic API error {d}: {s}", .{ @intFromEnum(fetch_result.status), response });
                    return LlmError.ApiError;
                }
                return response;
            },
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "OpenAI response parsing - text only" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}]}
    ;

    const OaiMessage = struct { content: ?[]const u8 = null };
    const OaiChoice = struct { message: OaiMessage };
    const OaiResp = struct { choices: []OaiChoice };

    const parsed = try std.json.parseFromSlice(OaiResp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello!", parsed.value.choices[0].message.content.?);
}

test "OpenAI response parsing - with tool calls" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
    ;

    const OaiFunc = struct { name: []const u8, arguments: []const u8 };
    const OaiToolCall = struct { id: []const u8, function: OaiFunc };
    const OaiMessage = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]OaiToolCall = null,
    };
    const OaiChoice = struct { message: OaiMessage };
    const OaiResp = struct { choices: []OaiChoice };

    const parsed = try std.json.parseFromSlice(OaiResp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const calls = parsed.value.choices[0].message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("bash", calls[0].function.name);
}

test "Anthropic response parsing - text only" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Hi there!"}],"stop_reason":"end_turn"}
    ;

    const Block = struct { type: ?[]const u8 = null, text: ?[]const u8 = null };
    const Resp = struct { content: []Block };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hi there!", parsed.value.content[0].text.?);
}

test "Anthropic response parsing - with tool use" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","type":"message","content":[{"type":"tool_use","id":"toolu_1","name":"bash","input":{"command":"ls"}}],"stop_reason":"tool_use"}
    ;

    const Block = struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const Resp = struct { content: []Block };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const block = parsed.value.content[0];
    try std.testing.expectEqualStrings("tool_use", block.type.?);
    try std.testing.expectEqualStrings("toolu_1", block.id.?);
    try std.testing.expectEqualStrings("bash", block.name.?);
}
