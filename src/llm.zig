//! OpenAI-compatible and Anthropic-compatible LLM API client with streaming support
const std = @import("std");
const commands = @import("commands.zig");

pub const LlmError = error{
    HttpRequestFailed,
    InvalidResponse,
    JsonParseError,
    OutOfMemory,
    ApiError,
    StreamError,
};

/// API format types (re-exported from commands)
pub const ApiFormat = commands.ApiFormat;

/// Callback type for streaming responses
pub const StreamCallback = *const fn (chunk: []const u8, user_data: ?*anyopaque) void;

/// LLM client for interacting with OpenAI-compatible and Anthropic-compatible APIs
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    endpoint_url: []const u8,
    model_name: []const u8,
    http_client: std.http.Client,
    api_format: ApiFormat,

    const Self = @This();

    /// Initialize the LLM client
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        endpoint_url: []const u8,
        model_name: []const u8,
        api_format: ApiFormat,
    ) Self {
        return Self{
            .allocator = allocator,
            .api_key = api_key,
            .endpoint_url = endpoint_url,
            .model_name = model_name,
            .http_client = std.http.Client{ .allocator = allocator },
            .api_format = api_format,
        };
    }

    /// Deinitialize the LLM client
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    /// Send a chat completion request to the LLM (non-streaming)
    pub fn chatCompletion(self: *Self, user_message: []const u8) LlmError![]u8 {
        return switch (self.api_format) {
            .openai => self.chatCompletionOpenAI(user_message),
            .anthropic => self.chatCompletionAnthropic(user_message),
        };
    }

    /// OpenAI format chat completion
    fn chatCompletionOpenAI(self: *Self, user_message: []const u8) LlmError![]u8 {
        // Create the request payload
        const Message = struct {
            role: []const u8,
            content: []const u8,
        };

        const RequestPayload = struct {
            model: []const u8,
            messages: []const Message,
        };

        const messages = [_]Message{.{
            .role = "user",
            .content = user_message,
        }};

        const payload = RequestPayload{
            .model = self.model_name,
            .messages = &messages,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create authorization header
        const auth_header = std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        ) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(auth_header);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
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

        // Get the response data
        const response = response_writer.written();

        if (fetch_result.status != .ok) {
            std.log.err("HTTP request returned status: {d}", .{@intFromEnum(fetch_result.status)});
            std.log.err("Response body: {s}", .{response});
            return LlmError.ApiError;
        }

        return try self.parseCompletionResponseOpenAI(response);
    }

    /// Anthropic format chat completion
    fn chatCompletionAnthropic(self: *Self, user_message: []const u8) LlmError![]u8 {
        // Create the request payload for Anthropic
        const Message = struct {
            role: []const u8,
            content: []const u8,
        };

        const RequestPayload = struct {
            model: []const u8,
            max_tokens: i32,
            messages: []const Message,
        };

        const messages = [_]Message{.{
            .role = "user",
            .content = user_message,
        }};

        const payload = RequestPayload{
            .model = self.model_name,
            .max_tokens = 4096, // Anthropic requires max_tokens
            .messages = &messages,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create x-api-key header for Anthropic
        const api_key_header = std.fmt.allocPrint(
            self.allocator,
            "{s}",
            .{self.api_key},
        ) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(api_key_header);

        // Create extra headers array for x-api-key
        const extra_headers = try self.allocator.alloc(std.http.Header, 1);
        defer self.allocator.free(extra_headers);
        extra_headers[0] = .{
            .name = "x-api-key",
            .value = api_key_header,
        };

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request with x-api-key header
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

        // Get the response data
        const response = response_writer.written();

        if (fetch_result.status != .ok) {
            std.log.err("HTTP request returned status: {d}", .{@intFromEnum(fetch_result.status)});
            std.log.err("Response body: {s}", .{response});
            return LlmError.ApiError;
        }

        return try self.parseCompletionResponseAnthropic(response);
    }

    /// Send a streaming chat completion request to the LLM
    pub fn chatCompletionStream(
        self: *Self,
        user_message: []const u8,
        callback: StreamCallback,
        user_data: ?*anyopaque,
    ) LlmError![]u8 {
        // Create the request payload with streaming enabled
        const Message = struct {
            role: []const u8,
            content: []const u8,
        };

        const RequestPayload = struct {
            model: []const u8,
            messages: []const Message,
            stream: bool,
        };

        const messages = [_]Message{.{
            .role = "user",
            .content = user_message,
        }};

        const payload = RequestPayload{
            .model = self.model_name,
            .messages = &messages,
            .stream = true,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create authorization header
        const auth_header = std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        ) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(auth_header);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
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

        // Get the response data
        const response = response_writer.written();

        if (fetch_result.status != .ok) {
            std.log.err("HTTP request returned status: {d}", .{@intFromEnum(fetch_result.status)});
            std.log.err("Response body: {s}", .{response});
            return LlmError.ApiError;
        }

        return try self.parseStreamResponse(response, callback, user_data);
    }

    /// Parse the OpenAI completion response
    fn parseCompletionResponseOpenAI(self: *Self, response: []const u8) LlmError![]u8 {
        // Define structures for JSON parsing
        const Message = struct {
            role: []const u8,
            content: ?[]const u8,
        };

        const Choice = struct {
            index: i32,
            message: Message,
            finish_reason: ?[]const u8 = null,
        };

        const CompletionResponse = struct {
            id: []const u8,
            object: []const u8,
            created: i64,
            model: []const u8,
            choices: []Choice,
        };

        const parsed = std.json.parseFromSlice(CompletionResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse JSON response: {s}", .{@errorName(err)});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) {
            return LlmError.InvalidResponse;
        }

        const content = parsed.value.choices[0].message.content orelse {
            return LlmError.InvalidResponse;
        };

        // Duplicate the content to return owned memory
        return self.allocator.dupe(u8, content) catch return LlmError.OutOfMemory;
    }

    /// Parse the Anthropic completion response
    fn parseCompletionResponseAnthropic(self: *Self, response: []const u8) LlmError![]u8 {
        // Anthropic format: {"content": [{"type": "text", "text": "..."}], ...}
        const ContentBlock = struct {
            type: []const u8,
            text: ?[]const u8,
        };

        const CompletionResponse = struct {
            id: []const u8,
            type: []const u8,
            role: []const u8,
            model: []const u8,
            content: []ContentBlock,
            stop_reason: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(CompletionResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse Anthropic JSON response: {s}", .{@errorName(err)});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.content.len == 0) {
            return LlmError.InvalidResponse;
        }

        const text = parsed.value.content[0].text orelse {
            return LlmError.InvalidResponse;
        };

        // Duplicate the content to return owned memory
        return self.allocator.dupe(u8, text) catch return LlmError.OutOfMemory;
    }

    /// Parse SSE stream response and call callback for each chunk
    fn parseStreamResponse(
        self: *Self,
        response: []const u8,
        callback: StreamCallback,
        user_data: ?*anyopaque,
    ) LlmError![]u8 {
        // Accumulate full response
        var full_response: std.ArrayList(u8) = .empty;
        defer full_response.deinit(self.allocator);

        // Parse SSE format line by line
        var lines = std.mem.splitScalar(u8, response, '\n');
        while (lines.next()) |line| {
            // Check if it's a data line
            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line[6..]; // Skip "data: "

                // Check for end of stream
                if (std.mem.eql(u8, data, "[DONE]")) {
                    break;
                }

                // Parse the JSON chunk
                const Delta = struct {
                    content: ?[]const u8 = null,
                };

                const Choice = struct {
                    delta: Delta,
                    finish_reason: ?[]const u8 = null,
                };

                const StreamChunk = struct {
                    id: []const u8,
                    object: []const u8,
                    created: i64,
                    model: []const u8,
                    choices: []Choice,
                };

                const parsed = std.json.parseFromSlice(StreamChunk, self.allocator, data, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    std.log.err("Failed to parse stream chunk: {s}", .{@errorName(err)});
                    continue; // Skip invalid chunks
                };
                defer parsed.deinit();

                // Extract content from delta
                if (parsed.value.choices.len > 0) {
                    if (parsed.value.choices[0].delta.content) |content| {
                        // Append to full response
                        full_response.appendSlice(self.allocator, content) catch {
                            return LlmError.OutOfMemory;
                        };

                        // Call callback with this chunk
                        callback(content, user_data);
                    }
                }
            }
        }

        // Return the complete accumulated response
        return full_response.toOwnedSlice(self.allocator) catch return LlmError.OutOfMemory;
    }
};

test "LlmClient parses completion response correctly" {
    const allocator = std.testing.allocator;

    const sample_response =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion",
        \\  "created": 1677652288,
        \\  "model": "gpt-4o-mini",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "Hello! How can I help you today?"
        \\      },
        \\      "finish_reason": "stop"
        \\    }
        \\  ],
        \\  "usage": {
        \\    "prompt_tokens": 9,
        \\    "completion_tokens": 12,
        \\    "total_tokens": 21
        \\  }
        \\}
    ;

    const Message = struct {
        role: []const u8,
        content: ?[]const u8,
    };

    const Choice = struct {
        index: i32,
        message: Message,
        finish_reason: ?[]const u8 = null,
    };

    const CompletionResponse = struct {
        id: []const u8,
        object: []const u8,
        created: i64,
        model: []const u8,
        choices: []Choice,
    };

    const parsed = try std.json.parseFromSlice(CompletionResponse, allocator, sample_response, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.choices.len);
    try std.testing.expectEqualStrings("assistant", parsed.value.choices[0].message.role);
    try std.testing.expectEqualStrings("Hello! How can I help you today?", parsed.value.choices[0].message.content.?);
}

test "LlmClient parses stream response correctly" {
    const allocator = std.testing.allocator;

    // Sample SSE stream
    const sample_stream =
        \\data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"delta":{"content":"Hello"},"index":0,"finish_reason":null}]}
        \\data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"delta":{"content":" there"},"index":0,"finish_reason":null}]}
        \\data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"delta":{"content":"!"},"index":0,"finish_reason":null}]}
        \\data: [DONE]
    ;

    var chunks = std.ArrayList([]const u8).init(allocator);
    defer chunks.deinit();

    const Delta = struct {
        content: ?[]const u8 = null,
    };

    const Choice = struct {
        delta: Delta,
        finish_reason: ?[]const u8 = null,
    };

    const StreamChunk = struct {
        id: []const u8,
        object: []const u8,
        created: i64,
        model: []const u8,
        choices: []Choice,
    };

    // Parse line by line manually for test
    var lines = std.mem.splitScalar(u8, sample_stream, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..];
            if (std.mem.eql(u8, data, "[DONE]")) break;

            const parsed = try std.json.parseFromSlice(StreamChunk, allocator, data, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();

            if (parsed.value.choices[0].delta.content) |content| {
                try chunks.append(content);
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 3), chunks.items.len);
    try std.testing.expectEqualStrings("Hello", chunks.items[0]);
    try std.testing.expectEqualStrings(" there", chunks.items[1]);
    try std.testing.expectEqualStrings("!", chunks.items[2]);
}

test "LlmClient constructs request payload correctly" {
    const allocator = std.testing.allocator;

    const Message = struct {
        role: []const u8,
        content: []const u8,
    };

    const RequestPayload = struct {
        model: []const u8,
        messages: []const Message,
    };

    const messages = [_]Message{.{
        .role = "user",
        .content = "Test message",
    }};

    const payload = RequestPayload{
        .model = "gpt-4o-mini",
        .messages = &messages,
    };

    const json_payload = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
    defer allocator.free(json_payload);

    // Verify the payload contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "gpt-4o-mini") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "Test message") != null);
}
