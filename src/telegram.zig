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
    const MAX_MESSAGE_LEN = 4096;

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

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.allocator.free(self.base_url);
    }

    /// Poll for updates from Telegram using long polling
    pub fn pollUpdates(self: *Self, timeout: u32) TelegramError![]Message {
        const offset_param: ?[]u8 = if (self.last_update_id) |id|
            try std.fmt.allocPrint(self.allocator, "&offset={d}", .{id + 1})
        else
            null;
        defer if (offset_param) |p| self.allocator.free(p);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/getUpdates?limit=10&timeout={d}{s}",
            .{ self.base_url, timeout, offset_param orelse "" },
        );
        defer self.allocator.free(url);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("HTTP request failed: {s}", .{@errorName(err)});
            return TelegramError.HttpRequestFailed;
        };

        const response = response_writer.written();

        if (fetch_result.status != .ok) {
            std.log.err("HTTP {d}: {s}", .{ @intFromEnum(fetch_result.status), response });
            return TelegramError.HttpRequestFailed;
        }

        return try self.parseUpdates(response);
    }

    fn parseUpdates(self: *Self, response: []const u8) TelegramError![]Message {
        const User = struct { id: i64 };
        const Chat = struct { id: i64 };
        const TgMsg = struct {
            message_id: i64,
            from: ?User = null,
            chat: Chat,
            text: ?[]const u8 = null,
        };
        const Update = struct {
            update_id: i64,
            message: ?TgMsg = null,
        };
        const Resp = struct {
            ok: bool,
            result: []Update,
        };

        const parsed = std.json.parseFromSlice(Resp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            return TelegramError.JsonParseError;
        };
        defer parsed.deinit();

        if (!parsed.value.ok) return TelegramError.InvalidResponse;

        var messages: std.ArrayList(Message) = .empty;
        defer messages.deinit(self.allocator);

        for (parsed.value.result) |update| {
            // Always update offset to avoid reprocessing
            if (self.last_update_id == null or update.update_id > self.last_update_id.?) {
                self.last_update_id = update.update_id;
            }

            const msg = update.message orelse continue;
            const text = msg.text orelse continue;
            const user_id = if (msg.from) |from| from.id else 0;

            if (!config.isUserAllowed(user_id, self.allowed_users)) {
                std.log.warn("Unauthorized user {d}", .{user_id});
                continue;
            }

            const text_copy = self.allocator.dupe(u8, text) catch return TelegramError.OutOfMemory;
            errdefer self.allocator.free(text_copy);

            try messages.append(self.allocator, .{
                .update_id = update.update_id,
                .chat_id = msg.chat.id,
                .user_id = user_id,
                .text = text_copy,
                .message_id = msg.message_id,
            });
        }

        return messages.toOwnedSlice(self.allocator) catch return TelegramError.OutOfMemory;
    }

    /// Send a message, automatically splitting if >4096 chars
    pub fn sendMessage(self: *Self, chat_id: i64, text: []const u8) TelegramError!void {
        if (text.len == 0) return;

        var remaining = text;
        while (remaining.len > 0) {
            if (remaining.len <= MAX_MESSAGE_LEN) {
                _ = try self.sendRaw(chat_id, remaining);
                break;
            }
            // Find a good split point (last newline before limit)
            var split: usize = MAX_MESSAGE_LEN;
            while (split > 0 and remaining[split - 1] != '\n') split -= 1;
            if (split == 0) split = MAX_MESSAGE_LEN; // no newline, hard split
            _ = try self.sendRaw(chat_id, remaining[0..split]);
            remaining = remaining[split..];
        }
    }

    /// Send a message and return the message_id (for later editing)
    pub fn sendMessageReturningId(self: *Self, chat_id: i64, text: []const u8) TelegramError!i64 {
        return self.sendRaw(chat_id, text);
    }

    /// Edit an existing message
    pub fn editMessage(self: *Self, chat_id: i64, message_id: i64, text: []const u8) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/editMessageText", .{self.base_url});
        defer self.allocator.free(url);

        const Payload = struct { chat_id: i64, message_id: i64, text: []const u8 };
        const payload = Payload{ .chat_id = chat_id, .message_id = message_id, .text = text };

        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        _ = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to edit message: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };
    }

    /// Send a single message chunk via Telegram API, returns message_id
    fn sendRaw(self: *Self, chat_id: i64, text: []const u8) TelegramError!i64 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendMessage", .{self.base_url});
        defer self.allocator.free(url);

        const Payload = struct { chat_id: i64, text: []const u8 };
        const payload = Payload{ .chat_id = chat_id, .text = text };

        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

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
            std.log.err("Send message status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.SendFailed;
        }

        // Parse response to extract message_id
        const resp_body = response_writer.written();
        const MsgResult = struct { message_id: i64 };
        const SendResp = struct { ok: bool, result: ?MsgResult = null };
        const parsed = std.json.parseFromSlice(SendResp, self.allocator, resp_body, .{
            .ignore_unknown_fields = true,
        }) catch return 0;
        defer parsed.deinit();

        if (parsed.value.result) |r| return r.message_id;
        return 0;
    }

    /// Send typing indicator
    pub fn sendTyping(self: *Self, chat_id: i64) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendChatAction", .{self.base_url});
        defer self.allocator.free(url);

        const Payload = struct { chat_id: i64, action: []const u8 };
        const payload = Payload{ .chat_id = chat_id, .action = "typing" };

        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        _ = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch {};
    }

    /// Set the bot's command menu in Telegram
    pub fn setMyCommands(self: *Self) TelegramError!void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/setMyCommands", .{self.base_url});
        defer self.allocator.free(url);

        const BotCommand = struct { command: []const u8, description: []const u8 };
        const commands = [_]BotCommand{
            .{ .command = "start", .description = "Start the bot" },
            .{ .command = "help", .description = "Show commands" },
            .{ .command = "auto", .description = "Re-enable auto-routing" },
            .{ .command = "agents", .description = "List available agents" },
            .{ .command = "agent", .description = "Switch agent (e.g. /agent coder)" },
            .{ .command = "teams", .description = "List available teams" },
            .{ .command = "team", .description = "Activate a team (e.g. /team web_dev)" },
            .{ .command = "task", .description = "Show current task status" },
            .{ .command = "cancel", .description = "Cancel current task" },
            .{ .command = "clear", .description = "Clear conversation history" },
            .{ .command = "history", .description = "Show recent conversation" },
            .{ .command = "memory", .description = "Memory commands" },
            .{ .command = "reload", .description = "Reload agents/teams from disk" },
        };

        const CmdPayload = struct { commands: []const BotCommand };
        const payload = CmdPayload{ .commands = &commands };

        const json_payload = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload, .{})}) catch {
            return TelegramError.OutOfMemory;
        };
        defer self.allocator.free(json_payload);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .payload = json_payload,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to set commands: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (fetch_result.status != .ok) {
            return TelegramError.SendFailed;
        }

        std.log.info("Bot commands menu registered", .{});
    }
};

test "parse updates" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"ok":true,"result":[{"update_id":123,"message":{"message_id":1,"from":{"id":111},"chat":{"id":222},"text":"Hello"}}]}
    ;

    const User = struct { id: i64 };
    const Chat = struct { id: i64 };
    const TgMsg = struct {
        message_id: i64,
        from: ?User = null,
        chat: Chat,
        text: ?[]const u8 = null,
    };
    const Update = struct {
        update_id: i64,
        message: ?TgMsg = null,
    };
    const Resp = struct { ok: bool, result: []Update };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("Hello", parsed.value.result[0].message.?.text.?);
}
