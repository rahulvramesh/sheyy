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
    FileTooLarge,
    DownloadFailed,
};

/// File information from Telegram
pub const FileInfo = struct {
    file_id: []const u8,
    file_unique_id: []const u8,
    file_size: ?i64,
    file_path: ?[]const u8,

    pub fn deinit(self: FileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.file_id);
        allocator.free(self.file_unique_id);
        if (self.file_path) |p| allocator.free(p);
    }
};

/// Photo size variant
pub const PhotoSize = struct {
    file_id: []const u8,
    file_unique_id: []const u8,
    width: i64,
    height: i64,
    file_size: ?i64,

    pub fn deinit(self: PhotoSize, allocator: std.mem.Allocator) void {
        allocator.free(self.file_id);
        allocator.free(self.file_unique_id);
    }
};

/// Represents a Telegram message
pub const Message = struct {
    update_id: i64,
    chat_id: i64,
    user_id: i64,
    text: ?[]const u8,
    message_id: i64,
    caption: ?[]const u8,
    photos: ?[]PhotoSize,
    document: ?FileInfo,
    has_file: bool,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        if (self.caption) |c| allocator.free(c);
        if (self.photos) |photos| {
            for (photos) |photo| photo.deinit(allocator);
            allocator.free(photos);
        }
        if (self.document) |doc| doc.deinit(allocator);
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
    const MAX_PHOTO_SIZE: i64 = 20 * 1024 * 1024; // 20MB
    const MAX_DOC_SIZE: i64 = 50 * 1024 * 1024; // 50MB

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
        const TgPhoto = struct {
            file_id: []const u8,
            file_unique_id: []const u8,
            width: i64,
            height: i64,
            file_size: ?i64 = null,
        };
        const TgDocument = struct {
            file_id: []const u8,
            file_unique_id: []const u8,
            file_name: ?[]const u8 = null,
            mime_type: ?[]const u8 = null,
            file_size: ?i64 = null,
        };
        const TgMsg = struct {
            message_id: i64,
            from: ?User = null,
            chat: Chat,
            text: ?[]const u8 = null,
            caption: ?[]const u8 = null,
            photo: ?[]TgPhoto = null,
            document: ?TgDocument = null,
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
            const user_id = if (msg.from) |from| from.id else 0;

            if (!config.isUserAllowed(user_id, self.allowed_users)) {
                std.log.warn("Unauthorized user {d}", .{user_id});
                continue;
            }

            // Skip messages with no content we can handle
            const has_content = msg.text != null or msg.caption != null or
                msg.photo != null or msg.document != null;
            if (!has_content) continue;

            // Parse text
            const text_copy: ?[]const u8 = if (msg.text) |t|
                self.allocator.dupe(u8, t) catch null
            else
                null;
            errdefer if (text_copy) |t| self.allocator.free(t);

            // Parse caption
            const caption_copy: ?[]const u8 = if (msg.caption) |c|
                self.allocator.dupe(u8, c) catch null
            else
                null;
            errdefer if (caption_copy) |c| self.allocator.free(c);

            // Parse photos - use largest photo (last in array)
            var photos: ?[]PhotoSize = null;
            if (msg.photo) |tg_photos| {
                if (tg_photos.len > 0) {
                    // Use largest photo (last in array)
                    const largest = tg_photos[tg_photos.len - 1];
                    const photo_arr = self.allocator.alloc(PhotoSize, 1) catch null;
                    if (photo_arr) |arr| {
                        arr[0] = .{
                            .file_id = self.allocator.dupe(u8, largest.file_id) catch continue,
                            .file_unique_id = self.allocator.dupe(u8, largest.file_unique_id) catch continue,
                            .width = largest.width,
                            .height = largest.height,
                            .file_size = largest.file_size,
                        };
                        photos = photo_arr;
                    }
                }
            }
            errdefer if (photos) |p| {
                for (p) |photo| photo.deinit(self.allocator);
                self.allocator.free(p);
            };

            // Parse document
            var document: ?FileInfo = null;
            if (msg.document) |doc| {
                document = FileInfo{
                    .file_id = self.allocator.dupe(u8, doc.file_id) catch continue,
                    .file_unique_id = self.allocator.dupe(u8, doc.file_unique_id) catch continue,
                    .file_size = doc.file_size,
                    .file_path = null,
                };
            }
            errdefer if (document) |d| d.deinit(self.allocator);

            const has_file = photos != null or document != null;

            try messages.append(self.allocator, .{
                .update_id = update.update_id,
                .chat_id = msg.chat.id,
                .user_id = user_id,
                .text = text_copy,
                .message_id = msg.message_id,
                .caption = caption_copy,
                .photos = photos,
                .document = document,
                .has_file = has_file,
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
            .{ .command = "files", .description = "List available files in workspace" },
            .{ .command = "sendfile", .description = "Send a file from workspace" },
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

    /// Get file info from Telegram (returns file_path for downloading)
    pub fn getFile(self: *Self, file_id: []const u8) TelegramError!FileInfo {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/getFile", .{self.base_url});
        defer self.allocator.free(url);

        const Payload = struct { file_id: []const u8 };
        const payload = Payload{ .file_id = file_id };

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
            std.log.err("Failed to get file info: {s}", .{@errorName(err)});
            return TelegramError.HttpRequestFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Get file status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.HttpRequestFailed;
        }

        const FileResult = struct {
            file_id: []const u8,
            file_unique_id: []const u8,
            file_size: ?i64 = null,
            file_path: ?[]const u8 = null,
        };
        const GetFileResp = struct { ok: bool, result: ?FileResult = null };

        const parsed = std.json.parseFromSlice(GetFileResp, self.allocator, response_writer.written(), .{
            .ignore_unknown_fields = true,
        }) catch return TelegramError.JsonParseError;
        defer parsed.deinit();

        if (!parsed.value.ok or parsed.value.result == null) {
            return TelegramError.InvalidResponse;
        }

        const result = parsed.value.result.?;
        return FileInfo{
            .file_id = try self.allocator.dupe(u8, result.file_id),
            .file_unique_id = try self.allocator.dupe(u8, result.file_unique_id),
            .file_size = result.file_size,
            .file_path = if (result.file_path) |p| try self.allocator.dupe(u8, p) else null,
        };
    }

    /// Download a file from Telegram servers
    pub fn downloadFile(self: *Self, file_path: []const u8) TelegramError![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/file/bot{s}/{s}", .{ self.bot_token, file_path });
        defer self.allocator.free(url);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to download file: {s}", .{@errorName(err)});
            return TelegramError.DownloadFailed;
        };

        if (fetch_result.status != .ok) {
            std.log.err("Download file status: {d}", .{@intFromEnum(fetch_result.status)});
            return TelegramError.DownloadFailed;
        }

        return try self.allocator.dupe(u8, response_writer.written());
    }

    /// Send a photo with optional caption
    pub fn sendPhoto(self: *Self, chat_id: i64, photo_path: []const u8, caption: ?[]const u8) TelegramError!void {
        // Check file size
        const file_size = std.fs.cwd().statFile(photo_path) catch |err| {
            std.log.err("Failed to stat photo file: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (file_size.size > MAX_PHOTO_SIZE) {
            std.log.err("Photo file too large: {d} bytes (max {d})", .{ file_size.size, MAX_PHOTO_SIZE });
            return TelegramError.FileTooLarge;
        }

        // Read file content
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, photo_path, @intCast(MAX_PHOTO_SIZE)) catch |err| {
            std.log.err("Failed to read photo file: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };
        defer self.allocator.free(file_content);

        // Build multipart form data
        const boundary = "----ZigBotBoundary";
        var form_data: std.ArrayList(u8) = .empty;
        defer form_data.deinit(self.allocator);
        const w = form_data.writer(self.allocator);

        // chat_id field
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n", .{});
        try w.print("{d}\r\n", .{chat_id});

        // caption field
        if (caption) |c| {
            try w.print("--{s}\r\n", .{boundary});
            try w.print("Content-Disposition: form-data; name=\"caption\"\r\n\r\n", .{});
            try w.print("{s}\r\n", .{c});
        }

        // photo file
        const filename = std.fs.path.basename(photo_path);
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"photo\"; filename=\"{s}\"\r\n", .{filename});
        try w.print("Content-Type: image/jpeg\r\n\r\n", .{});
        try w.writeAll(file_content);
        try w.print("\r\n--{s}--\r\n", .{boundary});

        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendPhoto", .{self.base_url});
        defer self.allocator.free(url);

        const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(content_type);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        _ = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = content_type },
            },
            .payload = form_data.items,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to send photo: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };
    }

    /// Send a document with optional caption
    pub fn sendDocument(self: *Self, chat_id: i64, document_path: []const u8, caption: ?[]const u8) TelegramError!void {
        // Check file size
        const file_size = std.fs.cwd().statFile(document_path) catch |err| {
            std.log.err("Failed to stat document file: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };

        if (file_size.size > MAX_DOC_SIZE) {
            std.log.err("Document file too large: {d} bytes (max {d})", .{ file_size.size, MAX_DOC_SIZE });
            return TelegramError.FileTooLarge;
        }

        // Read file content
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, document_path, @intCast(MAX_DOC_SIZE)) catch |err| {
            std.log.err("Failed to read document file: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };
        defer self.allocator.free(file_content);

        // Build multipart form data
        const boundary = "----ZigBotBoundary";
        var form_data: std.ArrayList(u8) = .empty;
        defer form_data.deinit(self.allocator);
        const w = form_data.writer(self.allocator);

        // chat_id field
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n", .{});
        try w.print("{d}\r\n", .{chat_id});

        // caption field
        if (caption) |c| {
            try w.print("--{s}\r\n", .{boundary});
            try w.print("Content-Disposition: form-data; name=\"caption\"\r\n\r\n", .{});
            try w.print("{s}\r\n", .{c});
        }

        // document file
        const filename = std.fs.path.basename(document_path);
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"document\"; filename=\"{s}\"\r\n", .{filename});
        try w.print("Content-Type: application/octet-stream\r\n\r\n", .{});
        try w.writeAll(file_content);
        try w.print("\r\n--{s}--\r\n", .{boundary});

        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendDocument", .{self.base_url});
        defer self.allocator.free(url);

        const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(content_type);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        _ = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = content_type },
            },
            .payload = form_data.items,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.log.err("Failed to send document: {s}", .{@errorName(err)});
            return TelegramError.SendFailed;
        };
    }

    // ── Streaming Message Support ─────────────────────────────────

    /// Manager for handling streaming message updates with rate limiting
    pub const StreamMessageManager = struct {
        client: ?*TelegramClient,
        allocator: std.mem.Allocator,
        chat_id: i64,
        message_id: i64,
        buffer: std.ArrayList(u8),
        last_edit_time: i64,
        min_edit_interval_ms: i64 = 3000, // Max 20 edits/minute = 1 per 3 seconds
        max_message_len: usize = 4096,
        placeholder: []const u8 = "⏳ Thinking...",
        is_complete: bool = false,
        mutex: std.Thread.Mutex,

        const ManagerSelf = @This();

        pub fn init(client: *TelegramClient, chat_id: i64) TelegramError!ManagerSelf {
            // Send initial placeholder message
            const message_id = try client.sendMessageReturningId(chat_id, ManagerSelf.placeholder);

            return ManagerSelf{
                .client = client,
                .allocator = client.allocator,
                .chat_id = chat_id,
                .message_id = message_id,
                .buffer = .empty,
                .last_edit_time = std.time.milliTimestamp(),
                .mutex = .{},
                .is_complete = false,
            };
        }

        pub fn deinit(self: *ManagerSelf) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.buffer.deinit(self.allocator);
        }

        /// Append content to buffer and flush if needed
        pub fn append(self: *ManagerSelf, content: []const u8) TelegramError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_complete) return;

            try self.buffer.appendSlice(self.allocator, content);

            // Check if we should flush based on time
            const now = std.time.milliTimestamp();
            if (now - self.last_edit_time >= self.min_edit_interval_ms) {
                try self.flushLocked();
            }
        }

        /// Force flush buffer to Telegram
        pub fn flush(self: *ManagerSelf) TelegramError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.flushLocked();
        }

        fn flushLocked(self: *ManagerSelf) TelegramError!void {
            if (self.is_complete or self.buffer.items.len == 0) return;

            const now = std.time.milliTimestamp();

            // Rate limiting check
            if (now - self.last_edit_time < self.min_edit_interval_ms) {
                return;
            }

            // Truncate if too long (leave room for ellipsis)
            var text_to_send: []const u8 = self.buffer.items;
            var needs_ellipsis = false;

            if (text_to_send.len > self.max_message_len - 3) {
                text_to_send = text_to_send[0 .. self.max_message_len - 3];
                needs_ellipsis = true;
            }

            // Prepare final text
            var display_text: []u8 = undefined;
            if (needs_ellipsis) {
                display_text = try self.allocator.alloc(u8, text_to_send.len + 3);
                @memcpy(display_text[0..text_to_send.len], text_to_send);
                @memcpy(display_text[text_to_send.len..], "...");
            } else {
                display_text = try self.allocator.dupe(u8, text_to_send);
            }
            defer self.allocator.free(display_text);

            // Send edit request (only if we have a valid client)
            if (self.client) |c| {
                c.editMessage(self.chat_id, self.message_id, display_text) catch |err| {
                    std.log.warn("Failed to edit streaming message: {s}", .{@errorName(err)});
                    return;
                };
            }

            self.last_edit_time = now;
        }

        /// Finalize the message with complete content
        pub fn finalize(self: *ManagerSelf) TelegramError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_complete) return;
            self.is_complete = true;

            var text_to_send: []const u8 = self.buffer.items;
            if (text_to_send.len == 0) {
                text_to_send = "(No response)";
            }

            // Truncate if too long
            if (text_to_send.len > self.max_message_len) {
                text_to_send = text_to_send[0..self.max_message_len];
            }

            // Send final edit (only if we have a valid client)
            if (self.client) |c| {
                c.editMessage(self.chat_id, self.message_id, text_to_send) catch |err| {
                    std.log.warn("Failed to finalize streaming message: {s}", .{@errorName(err)});
                    return;
                };
            }
        }

        /// Start a background flush timer
        pub fn startFlushTimer(self: *ManagerSelf) void {
            // Schedule periodic flush every 1 second
            const timer_thread = std.Thread.spawn(.{}, flushTimerLoop, .{self}) catch |err| {
                std.log.warn("Failed to start flush timer: {s}", .{@errorName(err)});
                return;
            };
            timer_thread.detach();
        }

        fn flushTimerLoop(self: *ManagerSelf) void {
            while (true) {
                std.Thread.sleep(1 * std.time.ns_per_s); // 1 second
                self.mutex.lock();
                const is_complete = self.is_complete;
                self.mutex.unlock();
                if (is_complete) break;
                self.flush() catch {};
            }
        }
    };
};

test "parse text updates" {
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

test "parse photo updates" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"ok":true,"result":[{"update_id":123,"message":{"message_id":1,"from":{"id":111},"chat":{"id":222},"photo":[{"file_id":"small","file_unique_id":"usmall","width":100,"height":100,"file_size":1024},{"file_id":"large","file_unique_id":"ularge","width":800,"height":600,"file_size":20480}],"caption":"Test photo"}}]}
    ;

    const User = struct { id: i64 };
    const Chat = struct { id: i64 };
    const TgPhoto = struct {
        file_id: []const u8,
        file_unique_id: []const u8,
        width: i64,
        height: i64,
        file_size: ?i64 = null,
    };
    const TgMsg = struct {
        message_id: i64,
        from: ?User = null,
        chat: Chat,
        text: ?[]const u8 = null,
        caption: ?[]const u8 = null,
        photo: ?[]TgPhoto = null,
    };
    const Update = struct {
        update_id: i64,
        message: ?TgMsg = null,
    };
    const Resp = struct { ok: bool, result: []Update };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ok);
    const msg = parsed.value.result[0].message.?;
    try std.testing.expect(msg.photo != null);
    try std.testing.expect(msg.photo.?.len == 2);
    try std.testing.expectEqualStrings("Test photo", msg.caption.?);
}

test "parse document updates" {
    const allocator = std.testing.allocator;
    const sample =
        \\{"ok":true,"result":[{"update_id":123,"message":{"message_id":1,"from":{"id":111},"chat":{"id":222},"document":{"file_id":"doc123","file_unique_id":"unique_doc","file_name":"test.txt","mime_type":"text/plain","file_size":1024},"caption":"Test document"}}]}
    ;

    const User = struct { id: i64 };
    const Chat = struct { id: i64 };
    const TgDocument = struct {
        file_id: []const u8,
        file_unique_id: []const u8,
        file_name: ?[]const u8 = null,
        mime_type: ?[]const u8 = null,
        file_size: ?i64 = null,
    };
    const TgMsg = struct {
        message_id: i64,
        from: ?User = null,
        chat: Chat,
        text: ?[]const u8 = null,
        caption: ?[]const u8 = null,
        document: ?TgDocument = null,
    };
    const Update = struct {
        update_id: i64,
        message: ?TgMsg = null,
    };
    const Resp = struct { ok: bool, result: []Update };

    const parsed = try std.json.parseFromSlice(Resp, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ok);
    const msg = parsed.value.result[0].message.?;
    try std.testing.expect(msg.document != null);
    try std.testing.expectEqualStrings("test.txt", msg.document.?.file_name.?);
}

// ── Streaming Tests ────────────────────────────────────────────────

test "StreamMessageManager init fields" {
    // Verify struct fields and defaults
    var manager = TelegramClient.StreamMessageManager{
        .client = null,
        .allocator = std.testing.allocator,
        .chat_id = 123,
        .message_id = 456,
        .buffer = .empty,
        .last_edit_time = 0,
        .min_edit_interval_ms = 3000,
        .max_message_len = 4096,
        .placeholder = "⏳ Thinking...",
        .is_complete = false,
        .mutex = .{},
    };
    defer manager.buffer.deinit(manager.allocator);

    try std.testing.expectEqual(@as(i64, 123), manager.chat_id);
    try std.testing.expectEqual(@as(i64, 456), manager.message_id);
    try std.testing.expectEqual(@as(i64, 3000), manager.min_edit_interval_ms);
    try std.testing.expectEqual(@as(usize, 4096), manager.max_message_len);
    try std.testing.expectEqual(false, manager.is_complete);
    try std.testing.expectEqualStrings("⏳ Thinking...", manager.placeholder);
}

test "StreamMessageManager buffer operations" {
    var manager = TelegramClient.StreamMessageManager{
        .client = null,
        .allocator = std.testing.allocator,
        .chat_id = 123,
        .message_id = 456,
        .buffer = .empty,
        .last_edit_time = 0,
        .min_edit_interval_ms = 3000,
        .max_message_len = 4096,
        .placeholder = "⏳ Thinking...",
        .is_complete = false,
        .mutex = .{},
    };
    defer manager.buffer.deinit(manager.allocator);

    // Test append
    try manager.append("Hello");
    try std.testing.expectEqualStrings("Hello", manager.buffer.items);

    // Test append more
    try manager.append(" World");
    try std.testing.expectEqualStrings("Hello World", manager.buffer.items);

    // Test that finalized manager rejects appends
    manager.is_complete = true;
    // This append should be ignored due to is_complete check
    try manager.append("!");
    // Buffer should still be "Hello World" because is_complete is true
    try std.testing.expectEqualStrings("Hello World", manager.buffer.items);
}
