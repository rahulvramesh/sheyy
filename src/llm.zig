//! OpenAI-compatible and Anthropic-compatible LLM API client
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

/// A chat message for the LLM API
pub const ChatMessage = struct {
    role: []const u8, // "system", "user", "assistant"
    content: []const u8,
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

    /// Send a chat completion with full messages array, model, temperature, and format
    pub fn chatCompletion(
        self: *Self,
        messages: []const ChatMessage,
        model_name: []const u8,
        temperature: f32,
        api_format: ApiFormat,
    ) LlmError![]u8 {
        return switch (api_format) {
            .openai => self.completionOpenAI(messages, model_name, temperature),
            .anthropic => self.completionAnthropic(messages, model_name, temperature),
        };
    }

    /// OpenAI format: messages array with system/user/assistant roles
    fn completionOpenAI(
        self: *Self,
        messages: []const ChatMessage,
        model_name: []const u8,
        temperature: f32,
    ) LlmError![]u8 {
        // Build JSON payload manually to handle the messages array
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"temperature\":{d:.2},\"messages\":[", .{ model_name, temperature });

        for (messages, 0..) |msg, i| {
            if (i > 0) try w.print(",", .{});
            // Use std.json.fmt to properly escape content
            try w.print("{{\"role\":\"{s}\",\"content\":{f}}}", .{
                msg.role,
                std.json.fmt(msg.content, .{}),
            });
        }
        try w.print("]}}", .{});

        const json_payload = payload_buf.items;

        // Auth header
        const auth_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch {
            return LlmError.OutOfMemory;
        };
        defer self.allocator.free(auth_header);

        // Response writer
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

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

        return self.parseOpenAIResponse(response);
    }

    /// Anthropic format: system as top-level field, messages without system role
    fn completionAnthropic(
        self: *Self,
        messages: []const ChatMessage,
        model_name: []const u8,
        temperature: f32,
    ) LlmError![]u8 {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);

        try w.print("{{\"model\":\"{s}\",\"max_tokens\":4096,\"temperature\":{d:.2}", .{ model_name, temperature });

        // Extract system message if present
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                try w.print(",\"system\":{f}", .{std.json.fmt(msg.content, .{})});
                break;
            }
        }

        // Non-system messages
        try w.print(",\"messages\":[", .{});
        var first = true;
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) continue;
            if (!first) try w.print(",", .{});
            try w.print("{{\"role\":\"{s}\",\"content\":{f}}}", .{
                msg.role,
                std.json.fmt(msg.content, .{}),
            });
            first = false;
        }
        try w.print("]}}", .{});

        const json_payload = payload_buf.items;

        // Anthropic uses x-api-key header
        const extra_headers = try self.allocator.alloc(std.http.Header, 1);
        defer self.allocator.free(extra_headers);
        extra_headers[0] = .{ .name = "x-api-key", .value = self.api_key };

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

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

        return self.parseAnthropicResponse(response);
    }

    fn parseOpenAIResponse(self: *Self, response: []const u8) LlmError![]u8 {
        const Message = struct { content: ?[]const u8 };
        const Choice = struct { message: Message };
        const Resp = struct { choices: []Choice };

        const parsed = std.json.parseFromSlice(Resp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.log.err("Failed to parse OpenAI response", .{});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) return LlmError.InvalidResponse;
        const content = parsed.value.choices[0].message.content orelse return LlmError.InvalidResponse;
        return self.allocator.dupe(u8, content) catch return LlmError.OutOfMemory;
    }

    fn parseAnthropicResponse(self: *Self, response: []const u8) LlmError![]u8 {
        const Block = struct { text: ?[]const u8 };
        const Resp = struct { content: []Block };

        const parsed = std.json.parseFromSlice(Resp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.log.err("Failed to parse Anthropic response", .{});
            return LlmError.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value.content.len == 0) return LlmError.InvalidResponse;
        const text = parsed.value.content[0].text orelse return LlmError.InvalidResponse;
        return self.allocator.dupe(u8, text) catch return LlmError.OutOfMemory;
    }
};

test "OpenAI response parsing" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}]}
    ;

    const Message = struct { content: ?[]const u8 };
    const Choice = struct { message: Message };
    const Resp = struct { choices: []Choice };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello!", parsed.value.choices[0].message.content.?);
}

test "Anthropic response parsing" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"id":"x","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Hi there!"}],"stop_reason":"end_turn"}
    ;

    const Block = struct { text: ?[]const u8 };
    const Resp = struct { content: []Block };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hi there!", parsed.value.content[0].text.?);
}
