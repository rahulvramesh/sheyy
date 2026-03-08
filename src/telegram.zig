//! Telegram Bot API client for polling and sending messages
const std = @import("std");
const config = @import("config.zig");

pub const TelegramError = error{
    HttpRequestFailed,
    InvalidResponse,
    JsonParseError,
    OutOfMemory,
    SendFailed,
    UnauthorizedUser,
};

/// Represents a Telegram message
pub const Message = struct {
    update_id: i64,
    chat_id: i64,
    user_id: i64,
    text: []const u8,
    message_id: i64,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Telegram client for interacting with the Bot API
pub const TelegramClient = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    http_client: std.http.Client,
    base_url: []const u8,
    last_update_id: ?i64,
    allowed_users: []const i64,

    const Self = @This();

    /// Initialize the Telegram client
    pub fn init(allocator: std.mem.Allocator, bot_token: []const u8, allowed_users: []const i64) !Self {
        const base_url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}", .{bot_token});
        errdefer allocator.free(base_url);

        return Self{
            .allocator = allocator,
            .bot_token = bot_token,
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
            .last_update_id = null,
            .allowed_users = allowed_users,
        };
    }

    /// Deinitialize the Telegram client and free resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.allocator.free(self.base_url);
    }

    /// Poll for updates from Telegram using long polling
    pub fn pollUpdates(self: *Self, timeout: u32) TelegramError![]Message {
        // Build offset parameter separately if needed
        const offset_param: ?[]u8 = if (self.last_update_id) |id|
            try std.fmt.allocPrint(self.allocator, "&offset={d}", .{id + 1})
        else
            null;
        defer if (offset_param) |p| self.allocator.free(p);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/getUpdates?limit=10&timeout={d}{s}",
            .{
                self.base_url,
                timeout,
                offset_param orelse "",
            },
        );
        defer self.allocator.free(url);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP GET request
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("HTTP request failed: {s}", .{@errorName(err)});
            return TelegramError.HttpRequestFailed;
        };

        // Get the response data
        const response = response_writer.written();

        if (fetch_result.status != .ok) {
            std.log.err("HTTP request returned status: {d}", .{@intFromEnum(fetch_result.status)});
            std.log.err("Response body: {s}", .{response});
            return TelegramError.HttpRequestFailed;
        }

        return try self.parseUpdates(response);
    }

    /// Parse the updates response from Telegram
    fn parseUpdates(self: *Self, response: []const u8) TelegramError![]Message {
        // Define structures for JSON parsing
        const User = struct {
            id: i64,
        };

        const Chat = struct {
            id: i64,
        };

        const TelegramMessage = struct {
            message_id: i64,
            from: ?User = null,
            chat: Chat,
            text: ?[]const u8 = null,
            date: i64 = 0,
        };

        const Update = struct {
            update_id: i64,
            message: ?TelegramMessage = null,
        };

        const UpdatesResponse = struct {
            ok: bool,
            result: []Update,
        };

        const parsed = std.json.parseFromSlice(UpdatesResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse JSON: {s}", .{@errorName(err)});
            return TelegramError.JsonParseError;
        };
        defer parsed.deinit();

        if (!parsed.value.ok) {
            return TelegramError.InvalidResponse;
        }

        var messages: std.ArrayList(Message) = .empty;
        defer messages.deinit(self.allocator);

        for (parsed.value.result) |update| {
            if (update.message) |msg| {
                if (msg.text) |text| {
                    // Get user ID from the message
                    const user_id = if (msg.from) |from| from.id else 0;

                    // Check if user is authorized
                    if (!config.isUserAllowed(user_id, self.allowed_users)) {
                        std.log.warn("Unauthorized access attempt from user {d}", .{user_id});
                        // Still update last_update_id to avoid reprocessing
                        if (self.last_update_id == null or update.update_id > self.last_update_id.?) {
                            self.last_update_id = update.update_id;
                        }
                        continue;
                    }

                    const text_copy = self.allocator.dupe(u8, text) catch return TelegramError.OutOfMemory;
                    errdefer self.allocator.free(text_copy);

                    const message = Message{
                        .update_id = update.update_id,
                        .chat_id = msg.chat.id,
                        .user_id = user_id,
                        .text = text_copy,
                        .message_id = msg.message_id,
                    };

                    try messages.append(self.allocator, message);

                    // Update last_update_id for next poll
                    if (self.last_update_id == null or update.update_id > self.last_update_id.?) {
                        self.last_update_id = update.update_id;
                    }
                }
            }
        }

        return messages.toOwnedSlice(self.allocator) catch return TelegramError.OutOfMemory;
    }

    /// Send a message to a chat
    pub fn sendMessage(self: *Self, chat_id: i64, text: []const u8) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendMessage", .{self.base_url});
        defer self.allocator.free(url);

        // Create JSON payload
        const Payload = struct {
            chat_id: i64,
            text: []const u8,
        };

        const payload = Payload{
            .chat_id = chat_id,
            .text = text,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to send message: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Send message returned status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.SendFailed;
        }

        // Parse response to verify success
        const SendResponse = struct {
            ok: bool,
        };

        const response = response_writer.written();
        const parsed = std.json.parseFromSlice(SendResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            return TelegramError.JsonParseError;
        };
        defer parsed.deinit();

        if (!parsed.value.ok) {
            return TelegramError.SendFailed;
        }
    }

    /// Send typing action to indicate the bot is processing
    /// The typing status lasts for 5 seconds or until a message is sent
    pub fn sendTyping(self: *Self, chat_id: i64) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendChatAction", .{self.base_url});
        defer self.allocator.free(url);

        // Create JSON payload
        const Payload = struct {
            chat_id: i64,
            action: []const u8,
        };

        const payload = Payload{
            .chat_id = chat_id,
            .action = "typing",
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to send typing action: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Send typing action returned status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.SendFailed;
        }
    }

    /// Send a message draft for streaming responses (Bot API 9.3+)
    /// Allows sending partial messages while content is being generated
    pub fn sendMessageDraft(self: *Self, chat_id: i64, text: []const u8) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendMessageDraft", .{self.base_url});
        defer self.allocator.free(url);

        // Create JSON payload
        const Payload = struct {
            chat_id: i64,
            text: []const u8,
        };

        const payload = Payload{
            .chat_id = chat_id,
            .text = text,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to send message draft: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Send message draft returned status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.SendFailed;
        }
    }

    /// Set the bot's command menu in Telegram
    /// This shows a menu when users type "/" in the chat
    pub fn setMyCommands(self: *Self) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/setMyCommands", .{self.base_url});
        defer self.allocator.free(url);

        // Define bot commands
        const BotCommand = struct {
            command: []const u8,
            description: []const u8,
        };

        const commands = [_]BotCommand{
            .{ .command = "start", .description = "Start the bot and see welcome message" },
            .{ .command = "help", .description = "Show available commands" },
            .{ .command = "models", .description = "List available AI models" },
            .{ .command = "model", .description = "Switch to a specific model (e.g., /model kimi-k2.5)" },
            .{ .command = "current", .description = "Show current model" },
        };

        // Create JSON payload
        const Payload = struct {
            commands: []const BotCommand,
        };

        const payload = Payload{
            .commands = &commands,
        };

        // Stringify JSON using the new API
        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        // Create an allocating writer for the response
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        // Make HTTP POST request
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to set bot commands: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Set commands returned status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.SendFailed;
        }

        std.log.info("Bot commands menu registered successfully", .{});
    }
};

test "TelegramClient parses updates correctly" {
    const allocator = std.testing.allocator;

    const sample_response =
        \\{
        \\  "ok": true,
        \\  "result": [
        \\    {
        \\      "update_id": 123456789,
        \\      "message": {
        \\        "message_id": 1,
        \\        "from": {"id": 111111, "is_bot": false, "first_name": "Test"},
        \\        "chat": {"id": 222222, "type": "private"},
        \\        "date": 1234567890,
        \\        "text": "Hello, bot!"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const UpdatesResponse = struct {
        ok: bool,
        result: []struct {
            update_id: i64,
            message: ?struct {
                message_id: i64,
                chat: struct { id: i64 },
                text: ?[]const u8,
            },
        },
    };

    const parsed = try std.json.parseFromSlice(UpdatesResponse, allocator, sample_response, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.result.len);
    try std.testing.expectEqual(@as(i64, 123456789), parsed.value.result[0].update_id);
    try std.testing.expectEqualStrings("Hello, bot!", parsed.value.result[0].message.?.text.?);
}

test "isUserAllowed allows authorized users" {
    const allowed_users = &[_]i64{ 8203335867, 123456789 };

    try std.testing.expect(config.isUserAllowed(8203335867, allowed_users));
    try std.testing.expect(config.isUserAllowed(123456789, allowed_users));
    try std.testing.expect(!config.isUserAllowed(999999999, allowed_users));
}

test "isUserAllowed allows all when list is empty" {
    const empty_list: []const i64 = &.{};

    try std.testing.expect(config.isUserAllowed(8203335867, empty_list));
    try std.testing.expect(config.isUserAllowed(123456789, empty_list));
    try std.testing.expect(config.isUserAllowed(999999999, empty_list));
}
