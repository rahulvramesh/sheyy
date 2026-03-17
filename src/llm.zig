//! OpenAI-compatible and Anthropic-compatible LLM API client
//! Supports both plain text completions and tool-calling (function calling).
const std = @import("std");

pub const LlmError = error{
    HttpRequestFailed,
    InvalidResponse,
    JsonParseError,
    OutOfMemory,
    ApiError,
    RateLimitError,
    MaxRetriesExceeded,
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

/// Retry configuration for LLM API calls
pub const RetryConfig = struct {
    max_retries: u32 = 3,
    base_delay_ms: u64 = 1000, // 1 second
    max_delay_ms: u64 = 30000, // 30 seconds
    enable_jitter: bool = true,
};

/// Streaming token types yielded by the LLM
pub const StreamToken = union(enum) {
    content: []const u8, // Text content chunk
    tool_calls: []ToolCall, // Tool calls (typically at end)
    done, // Stream completed successfully
    stream_error: LlmError, // Error occurred
};

/// Callback handler for streaming responses
pub const StreamHandler = *const fn (token: StreamToken, user_data: ?*anyopaque) void;

/// Configuration for streaming requests
pub const StreamConfig = struct {
    handler: StreamHandler,
    user_data: ?*anyopaque = null,
    enable_streaming: bool = true,
};

/// HTTP response info for retry decision making
const HttpResponseInfo = struct {
    status: std.http.Status,
    body: []const u8,
};

/// LLM client for interacting with OpenAI-compatible and Anthropic-compatible APIs
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    endpoint_url: []const u8,
    http_client: std.http.Client,
    retry_config: RetryConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, endpoint_url: []const u8) Self {
        return Self{
            .allocator = allocator,
            .api_key = api_key,
            .endpoint_url = endpoint_url,
            .http_client = std.http.Client{ .allocator = allocator },
            .retry_config = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    pub fn setRetryConfig(self: *Self, config: RetryConfig) void {
        self.retry_config = config;
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

    /// Stream completion with tool-calling support
    pub fn chatCompletionStream(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        api_format: ApiFormat,
        tools_json: ?[]const u8,
        stream_config: StreamConfig,
    ) LlmError!void {
        if (!stream_config.enable_streaming) {
            // Fall back to non-streaming
            const response = try self.chatCompletionWithTools(messages, model_name, temperature, api_format, tools_json);
            defer response.deinit(self.allocator);

            if (response.content) |c| {
                stream_config.handler(.{ .content = c }, stream_config.user_data);
            }
            if (response.tool_calls) |calls| {
                // Duplicate tool calls for the handler
                const calls_copy = try self.allocator.dupe(ToolCall, calls);
                for (calls_copy) |*call| {
                    call.id = try self.allocator.dupe(u8, call.id);
                    call.function_name = try self.allocator.dupe(u8, call.function_name);
                    call.arguments_json = try self.allocator.dupe(u8, call.arguments_json);
                }
                stream_config.handler(.{ .tool_calls = calls_copy }, stream_config.user_data);
            }
            stream_config.handler(.done, stream_config.user_data);
            return;
        }

        return switch (api_format) {
            .openai => self.streamOpenAI(messages, model_name, temperature, tools_json, stream_config),
            .anthropic => self.streamAnthropic(messages, model_name, temperature, tools_json, stream_config),
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

        const response = try self.doHttpRequestWithRetry(payload_buf.items, .openai);
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

    // ── OpenAI Streaming ──────────────────────────────────────────

    fn streamOpenAI(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        tools_json: ?[]const u8,
        stream_config: StreamConfig,
    ) LlmError!void {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"temperature\":{d:.2},\"stream\":true,\"messages\":[", .{ model_name, temperature });

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

        self.doStreamingRequest(payload_buf.items, .openai, stream_config) catch |err| {
            stream_config.handler(.{ .stream_error = err }, stream_config.user_data);
            return err;
        };
    }

    fn parseOpenAIStreamChunk(self: *Self, line: []const u8, stream_config: StreamConfig) LlmError!bool {
        // SSE format: data: {...}
        if (!std.mem.startsWith(u8, line, "data: ")) return false;
        const data = line[6..]; // Skip "data: "

        // Check for stream end marker
        if (std.mem.eql(u8, data, "[DONE]")) {
            stream_config.handler(.done, stream_config.user_data);
            return true;
        }

        // Parse the delta
        const Delta = struct {
            content: ?[]const u8 = null,
        };
        const Choice = struct {
            delta: Delta,
            finish_reason: ?[]const u8 = null,
        };
        const StreamResp = struct {
            choices: []Choice,
        };

        const parsed = std.json.parseFromSlice(StreamResp, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            // Some chunks might not have content, that's ok
            return false;
        };
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) return false;
        const choice = parsed.value.choices[0];

        // Check if stream is finished
        if (choice.finish_reason) |reason| {
            if (!std.mem.eql(u8, reason, "null") and !std.mem.eql(u8, reason, "")) {
                stream_config.handler(.done, stream_config.user_data);
                return true;
            }
        }

        // Yield content if present
        if (choice.delta.content) |content| {
            if (content.len > 0) {
                const content_copy = self.allocator.dupe(u8, content) catch return LlmError.OutOfMemory;
                stream_config.handler(.{ .content = content_copy }, stream_config.user_data);
            }
        }

        return false;
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

        const response = try self.doHttpRequestWithRetry(payload_buf.items, .anthropic);
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

    // ── Anthropic Streaming ───────────────────────────────────────

    fn streamAnthropic(
        self: *Self,
        messages: []const RichMessage,
        model_name: []const u8,
        temperature: f32,
        tools_json: ?[]const u8,
        stream_config: StreamConfig,
    ) LlmError!void {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"max_tokens\":4096,\"temperature\":{d:.2},\"stream\":true", .{ model_name, temperature });

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

        self.doStreamingRequest(payload_buf.items, .anthropic, stream_config) catch |err| {
            stream_config.handler(.{ .stream_error = err }, stream_config.user_data);
            return err;
        };
    }

    fn parseAnthropicStreamChunk(self: *Self, line: []const u8, stream_config: StreamConfig) LlmError!bool {
        // Anthropic SSE format: event: <type>\ndata: {...}
        // We process "data:" lines after event lines
        if (!std.mem.startsWith(u8, line, "data: ")) return false;
        const data = line[6..]; // Skip "data: "

        // Parse the event data
        const ContentBlock = struct {
            type: []const u8,
            text: ?[]const u8 = null,
        };
        const Delta = struct {
            type: ?[]const u8 = null,
            text: ?[]const u8 = null,
            stop_reason: ?[]const u8 = null,
        };
        const StreamEvent = struct {
            type: []const u8,
            delta: ?Delta = null,
            content_block: ?ContentBlock = null,
        };

        const parsed = std.json.parseFromSlice(StreamEvent, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            return false;
        };
        defer parsed.deinit();

        const event_type = parsed.value.type;

        // Handle content_block_delta events (main text streaming)
        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            if (parsed.value.delta) |delta| {
                if (delta.text) |text| {
                    if (text.len > 0) {
                        const text_copy = self.allocator.dupe(u8, text) catch return LlmError.OutOfMemory;
                        stream_config.handler(.{ .content = text_copy }, stream_config.user_data);
                    }
                }
            }
        }

        // Handle message_stop event
        if (std.mem.eql(u8, event_type, "message_stop")) {
            stream_config.handler(.done, stream_config.user_data);
            return true;
        }

        // Check for stop_reason in delta (indicates completion)
        if (parsed.value.delta) |delta| {
            if (delta.stop_reason) |reason| {
                if (!std.mem.eql(u8, reason, "null") and !std.mem.eql(u8, reason, "")) {
                    stream_config.handler(.done, stream_config.user_data);
                    return true;
                }
            }
        }

        return false;
    }

    // ── HTTP Streaming Helper ─────────────────────────────────────

    fn doStreamingRequest(
        self: *Self,
        json_payload: []const u8,
        api_format: ApiFormat,
        stream_config: StreamConfig,
    ) LlmError!void {
        // Build request headers based on API format
        var headers: std.http.Headers = .{};
        var auth_header: ?[]u8 = null;
        var extra_headers: ?[]std.http.Header = null;

        defer {
            if (auth_header) |h| self.allocator.free(h);
            if (extra_headers) |eh| self.allocator.free(eh);
        }

        switch (api_format) {
            .openai => {
                auth_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch {
                    return LlmError.OutOfMemory;
                };
                headers.authorization = .{ .override = auth_header.? };
                headers.content_type = .{ .override = "application/json" };
            },
            .anthropic => {
                extra_headers = self.allocator.alloc(std.http.Header, 1) catch return LlmError.OutOfMemory;
                extra_headers.?[0] = .{ .name = "x-api-key", .value = self.api_key };
                headers.content_type = .{ .override = "application/json" };
            },
        }

        // Open connection
        const uri = std.Uri.parse(self.endpoint_url) catch {
            return LlmError.InvalidResponse;
        };

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var request = self.http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .headers = headers,
            .extra_headers = extra_headers,
        }) catch |err| {
            std.log.err("Failed to open HTTP connection: {s}", .{@errorName(err)});
            return LlmError.HttpRequestFailed;
        };
        defer request.deinit();

        request.transfer_encoding = .chunked;

        // Send headers
        request.send() catch |err| {
            std.log.err("Failed to send HTTP headers: {s}", .{@errorName(err)});
            return LlmError.HttpRequestFailed;
        };

        // Send body
        request.writer().writeAll(json_payload) catch |err| {
            std.log.err("Failed to send HTTP body: {s}", .{@errorName(err)});
            return LlmError.HttpRequestFailed;
        };
        request.finish() catch |err| {
            std.log.err("Failed to finish HTTP request: {s}", .{@errorName(err)});
            return LlmError.HttpRequestFailed;
        };

        // Wait for response
        request.wait() catch |err| {
            std.log.err("Failed to receive HTTP response: {s}", .{@errorName(err)});
            return LlmError.HttpRequestFailed;
        };

        const status: u16 = @intFromEnum(request.response.status);
        if (status == 429) {
            return LlmError.RateLimitError;
        }
        if (status >= 500 and status < 600) {
            return LlmError.HttpRequestFailed;
        }
        if (status != 200) {
            return LlmError.ApiError;
        }

        // Read and process SSE stream
        var reader = request.reader();
        var line_buf: [4096]u8 = undefined;
        var line_pos: usize = 0;
        var done = false;

        while (!done) {
            const byte = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.log.err("Error reading stream: {s}", .{@errorName(err)});
                    return LlmError.HttpRequestFailed;
                },
            };

            if (byte == '\n') {
                // Process complete line
                if (line_pos > 0) {
                    const line = line_buf[0..line_pos];
                    const is_done = switch (api_format) {
                        .openai => try self.parseOpenAIStreamChunk(line, stream_config),
                        .anthropic => try self.parseAnthropicStreamChunk(line, stream_config),
                    };
                    if (is_done) {
                        done = true;
                        break;
                    }
                }
                line_pos = 0;
            } else if (byte != '\r') {
                // Accumulate line (skip \r for Windows line endings)
                if (line_pos < line_buf.len) {
                    line_buf[line_pos] = byte;
                    line_pos += 1;
                }
            }
        }

        if (!done) {
            // Stream ended without explicit done signal
            stream_config.handler(.done, stream_config.user_data);
        }
    }

    // ── HTTP Helper with Retry ────────────────────────────────────

    fn doHttpRequestWithRetry(self: *Self, json_payload: []const u8, api_format: ApiFormat) LlmError![]const u8 {
        var attempt: u32 = 0;
        var last_error: ?LlmError = null;

        while (attempt <= self.retry_config.max_retries) {
            if (attempt > 0) {
                // Calculate backoff delay with exponential increase
                const delay_ms = self.calculateBackoffDelay(attempt);
                const jittered_delay_ms = self.addJitter(delay_ms);

                std.log.warn("LLM request retry {d}/{d} after {d}ms (error: {s})", .{
                    attempt,
                    self.retry_config.max_retries,
                    jittered_delay_ms,
                    if (last_error) |e| @errorName(e) else "unknown",
                });

                std.Thread.sleep(jittered_delay_ms * std.time.ns_per_ms);
            }

            // Attempt the HTTP request
            const result = self.doHttpRequestInternal(json_payload, api_format);

            switch (result) {
                .success => |response| {
                    if (attempt > 0) {
                        std.log.info("LLM request succeeded after {d} retries", .{attempt});
                    }
                    return response;
                },
                .failure => |err| {
                    last_error = err;

                    // Only retry on transient errors
                    if (!self.isRetryableError(err)) {
                        std.log.err("LLM request failed with non-retryable error: {s}", .{@errorName(err)});
                        return err;
                    }

                    attempt += 1;

                    // If we've exceeded max retries, return the last error
                    if (attempt > self.retry_config.max_retries) {
                        std.log.err("LLM request failed after {d} retries: {s}", .{
                            self.retry_config.max_retries,
                            @errorName(err),
                        });
                        return LlmError.MaxRetriesExceeded;
                    }
                },
            }
        }

        // Should never reach here, but just in case
        return last_error orelse LlmError.HttpRequestFailed;
    }

    fn calculateBackoffDelay(self: *Self, attempt: u32) u64 {
        // Exponential backoff: base_delay * 2^(attempt-1)
        const exponent = attempt - 1;
        var delay = self.retry_config.base_delay_ms;
        var i: u32 = 0;
        while (i < exponent) : (i += 1) {
            delay = delay * 2;
            // Prevent overflow
            if (delay > self.retry_config.max_delay_ms) {
                delay = self.retry_config.max_delay_ms;
                break;
            }
        }
        return @min(delay, self.retry_config.max_delay_ms);
    }

    fn addJitter(self: *Self, delay_ms: u64) u64 {
        if (!self.retry_config.enable_jitter) {
            return delay_ms;
        }

        // Add random jitter of up to +/- 25% of the delay
        // Use a simple PRNG based on current time
        const seed = @as(u64, @intCast(std.time.milliTimestamp()));
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        // Generate jitter factor between 0.75 and 1.25
        const jitter_factor = 0.75 + (random.float(f64) * 0.5);
        const jittered = @as(f64, @floatFromInt(delay_ms)) * jitter_factor;

        return @max(1, @as(u64, @intFromFloat(jittered)));
    }

    fn isRetryableError(self: *Self, err: anyerror) bool {
        _ = self;
        // Retry on network/timeout errors and rate limiting
        return switch (err) {
            error.HttpRequestFailed => true,
            error.RateLimitError => true,
            // Don't retry on these errors
            error.InvalidResponse => false,
            error.JsonParseError => false,
            error.OutOfMemory => false,
            error.ApiError => false,
            error.MaxRetriesExceeded => false,
            else => false,
        };
    }

    /// Result type for HTTP request attempts
    const HttpResult = union(enum) {
        success: []const u8,
        failure: LlmError,
    };

    fn doHttpRequestInternal(self: *Self, json_payload: []const u8, api_format: ApiFormat) HttpResult {
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_writer.deinit();

        switch (api_format) {
            .openai => {
                const auth_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch {
                    return .{ .failure = LlmError.OutOfMemory };
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
                    return .{ .failure = LlmError.HttpRequestFailed };
                };

                const response = response_writer.written();
                const status: u16 = @intFromEnum(fetch_result.status);

                // Check for rate limiting (429)
                if (status == 429) {
                    std.log.err("LLM API rate limited: {s}", .{response});
                    return .{ .failure = LlmError.RateLimitError };
                }

                // Check for server errors (5xx)
                if (status >= 500 and status < 600) {
                    std.log.err("LLM API server error {d}: {s}", .{ status, response });
                    return .{ .failure = LlmError.HttpRequestFailed };
                }

                if (fetch_result.status != .ok) {
                    std.log.err("LLM API error {d}: {s}", .{ status, response });
                    return .{ .failure = LlmError.ApiError };
                }
                return .{ .success = response };
            },
            .anthropic => {
                const extra_headers = self.allocator.alloc(std.http.Header, 1) catch return .{ .failure = LlmError.OutOfMemory };
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
                    return .{ .failure = LlmError.HttpRequestFailed };
                };

                const response = response_writer.written();
                const status: u16 = @intFromEnum(fetch_result.status);

                // Check for rate limiting (429)
                if (status == 429) {
                    std.log.err("Anthropic API rate limited: {s}", .{response});
                    return .{ .failure = LlmError.RateLimitError };
                }

                // Check for server errors (5xx)
                if (status >= 500 and status < 600) {
                    std.log.err("Anthropic API server error {d}: {s}", .{ status, response });
                    return .{ .failure = LlmError.HttpRequestFailed };
                }

                if (fetch_result.status != .ok) {
                    std.log.err("Anthropic API error {d}: {s}", .{ status, response });
                    return .{ .failure = LlmError.ApiError };
                }
                return .{ .success = response };
            },
        }
    }

    // Kept for backward compatibility - delegates to retry version
    fn doHttpRequest(self: *Self, json_payload: []const u8, api_format: ApiFormat) LlmError![]const u8 {
        return self.doHttpRequestWithRetry(json_payload, api_format);
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
        \\{"id":"x","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\\\"command\\\":\\\"ls\\\"}"}}]},"finish_reason":"tool_calls"}]}
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

test "RetryConfig default values" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expectEqual(@as(u64, 1000), config.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 30000), config.max_delay_ms);
    try std.testing.expectEqual(true, config.enable_jitter);
}

test "calculateBackoffDelay exponential growth" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    // Test exponential backoff delays
    try std.testing.expectEqual(@as(u64, 1000), client.calculateBackoffDelay(1)); // 1s
    try std.testing.expectEqual(@as(u64, 2000), client.calculateBackoffDelay(2)); // 2s
    try std.testing.expectEqual(@as(u64, 4000), client.calculateBackoffDelay(3)); // 4s
    try std.testing.expectEqual(@as(u64, 8000), client.calculateBackoffDelay(4)); // 8s
}

test "calculateBackoffDelay respects max_delay" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    // Set a low max_delay to test capping
    client.setRetryConfig(.{
        .max_retries = 5,
        .base_delay_ms = 1000,
        .max_delay_ms = 5000, // Cap at 5s
        .enable_jitter = false,
    });

    // Should be capped at max_delay
    try std.testing.expectEqual(@as(u64, 1000), client.calculateBackoffDelay(1)); // 1s
    try std.testing.expectEqual(@as(u64, 2000), client.calculateBackoffDelay(2)); // 2s
    try std.testing.expectEqual(@as(u64, 4000), client.calculateBackoffDelay(3)); // 4s
    try std.testing.expectEqual(@as(u64, 5000), client.calculateBackoffDelay(4)); // capped at 5s
    try std.testing.expectEqual(@as(u64, 5000), client.calculateBackoffDelay(5)); // capped at 5s
}

test "isRetryableError identifies transient errors" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    // Retryable errors - test each explicitly
    try std.testing.expect(client.isRetryableError(error.HttpRequestFailed));
    try std.testing.expect(client.isRetryableError(error.RateLimitError));

    // Non-retryable errors - test each explicitly
    try std.testing.expect(!client.isRetryableError(error.InvalidResponse));
    try std.testing.expect(!client.isRetryableError(error.JsonParseError));
    try std.testing.expect(!client.isRetryableError(error.OutOfMemory));
    try std.testing.expect(!client.isRetryableError(error.ApiError));
    try std.testing.expect(!client.isRetryableError(error.MaxRetriesExceeded));
}

test "addJitter produces reasonable values" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    const base_delay: u64 = 1000;

    // Test multiple times to account for randomness
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const jittered = client.addJitter(base_delay);

        // Jitter should be between 75% and 125% of base delay
        const min_expected = @as(u64, @intFromFloat(@as(f64, @floatFromInt(base_delay)) * 0.75));
        const max_expected = @as(u64, @intFromFloat(@as(f64, @floatFromInt(base_delay)) * 1.25));

        try std.testing.expect(jittered >= min_expected);
        try std.testing.expect(jittered <= max_expected);
        try std.testing.expect(jittered > 0);
    }
}

test "addJitter without jitter enabled" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    client.setRetryConfig(.{
        .max_retries = 3,
        .base_delay_ms = 1000,
        .enable_jitter = false,
    });

    const base_delay: u64 = 1000;
    const jittered = client.addJitter(base_delay);

    // Should return exact delay without jitter
    try std.testing.expectEqual(base_delay, jittered);
}

// ── Streaming Tests ────────────────────────────────────────────────

test "StreamToken types" {
    // Test content token
    const content_token = StreamToken{ .content = "Hello" };
    try std.testing.expectEqualStrings("Hello", content_token.content);

    // Test done token
    const done_token = StreamToken.done;
    try std.testing.expectEqual(StreamToken.done, done_token);

    // Test error token
    const error_token = StreamToken{ .stream_error = LlmError.ApiError };
    try std.testing.expectEqual(LlmError.ApiError, error_token.stream_error);
}

test "parseOpenAIStreamChunk - content delta" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    // Collect received tokens
    var received_content: std.ArrayList(u8) = .empty;
    defer received_content.deinit(allocator);
    var got_done = false;

    const TestContext = struct {
        content: *std.ArrayList(u8),
        done: *bool,
        allocator: std.mem.Allocator,

        pub fn handler(token: StreamToken, user_data: ?*anyopaque) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user_data.?)));
            switch (token) {
                .content => |c| {
                    ctx.content.appendSlice(ctx.allocator, c) catch {};
                    ctx.allocator.free(c);
                },
                .done => ctx.done.* = true,
                else => {},
            }
        }
    };

    var ctx = TestContext{ .content = &received_content, .done = &got_done, .allocator = allocator };

    const stream_config = StreamConfig{
        .handler = TestContext.handler,
        .user_data = &ctx,
    };

    // Test content chunk
    const chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}";
    const is_done = try client.parseOpenAIStreamChunk(chunk, stream_config);
    try std.testing.expect(!is_done);
    try std.testing.expectEqualStrings("Hello", received_content.items);

    // Test done chunk
    const done_chunk = "data: [DONE]";
    const really_done = try client.parseOpenAIStreamChunk(done_chunk, stream_config);
    try std.testing.expect(really_done);
    try std.testing.expect(got_done);
}

test "parseOpenAIStreamChunk - finish reason" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    var got_done: bool = false;

    const TestContext = struct {
        done: *bool,

        pub fn handler(token: StreamToken, user_data: ?*anyopaque) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user_data.?)));
            switch (token) {
                .done => ctx.done.* = true,
                else => {},
            }
        }
    };

    var ctx = TestContext{ .done = &got_done };

    const stream_config = StreamConfig{
        .handler = TestContext.handler,
        .user_data = &ctx,
    };

    // Test chunk with finish_reason=stop
    const chunk = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}";
    const is_done = try client.parseOpenAIStreamChunk(chunk, stream_config);
    try std.testing.expect(is_done);
    try std.testing.expect(got_done);
}

test "parseAnthropicStreamChunk - text delta" {
    const allocator = std.testing.allocator;
    var client = LlmClient.init(allocator, "test_key", "https://api.test.com");
    defer client.deinit();

    var received_content: std.ArrayList(u8) = .empty;
    defer received_content.deinit(allocator);
    var got_done: bool = false;

    const TestContext = struct {
        content: *std.ArrayList(u8),
        done: *bool,
        allocator: std.mem.Allocator,

        pub fn handler(token: StreamToken, user_data: ?*anyopaque) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user_data.?)));
            switch (token) {
                .content => |c| {
                    ctx.content.appendSlice(ctx.allocator, c) catch {};
                    ctx.allocator.free(c);
                },
                .done => ctx.done.* = true,
                else => {},
            }
        }
    };

    var ctx = TestContext{ .content = &received_content, .done = &got_done, .allocator = allocator };

    const stream_config = StreamConfig{
        .handler = TestContext.handler,
        .user_data = &ctx,
    };

    // Test content_block_delta event
    const chunk = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text\",\"text\":\"World\"}}";
    const is_done = try client.parseAnthropicStreamChunk(chunk, stream_config);
    try std.testing.expect(!is_done);
    try std.testing.expectEqualStrings("World", received_content.items);

    // Test message_stop event
    const stop_chunk = "data: {\"type\":\"message_stop\"}";
    const really_done = try client.parseAnthropicStreamChunk(stop_chunk, stream_config);
    try std.testing.expect(really_done);
}

test "StreamConfig defaults" {
    const config = StreamConfig{
        .handler = undefined,
    };
    try std.testing.expectEqual(true, config.enable_streaming);
    try std.testing.expectEqual(null, config.user_data);
}
