//! Command handler for Telegram bot commands
const std = @import("std");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");

pub const CommandError = error{
    UnknownCommand,
    InvalidArgument,
    OutOfMemory,
    SendFailed,
};

/// API format types
pub const ApiFormat = enum {
    openai,
    anthropic,
};

/// Available models that can be switched to
pub const AvailableModels = &[_]ModelInfo{
    .{ .id = "kimi-k2.5", .name = "Kimi K2.5", .description = "High quality general purpose model", .api_format = .openai, .endpoint_path = "/v1/chat/completions" },
    .{ .id = "glm-5", .name = "GLM-5", .description = "Fast and efficient", .api_format = .openai, .endpoint_path = "/v1/chat/completions" },
    .{ .id = "minimax-m2.5", .name = "MiniMax M2.5", .description = "Cost effective (Anthropic format)", .api_format = .anthropic, .endpoint_path = "/v1/messages" },
};

const ModelInfo = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    api_format: ApiFormat,
    endpoint_path: []const u8,
};

/// Bot state that can be modified by commands
pub const BotState = struct {
    allocator: std.mem.Allocator,
    current_model: []const u8,
    endpoint_url: []const u8,
    api_key: []const u8,
    api_format: ApiFormat,
    base_endpoint: []const u8, // Base URL without path

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, initial_model: []const u8, endpoint_url: []const u8, api_key: []const u8) !Self {
        // Determine initial API format and base endpoint from model
        var api_format: ApiFormat = .openai;
        var base_endpoint = try allocator.dupe(u8, endpoint_url);

        // Find the model info to set correct format
        for (AvailableModels) |model| {
            if (std.mem.eql(u8, model.id, initial_model)) {
                api_format = model.api_format;
                // Extract base endpoint (remove path if present)
                if (std.mem.lastIndexOf(u8, endpoint_url, "/v1/")) |idx| {
                    allocator.free(base_endpoint);
                    base_endpoint = try allocator.dupe(u8, endpoint_url[0..idx]);
                }
                break;
            }
        }

        return Self{
            .allocator = allocator,
            .current_model = try allocator.dupe(u8, initial_model),
            .endpoint_url = try allocator.dupe(u8, endpoint_url),
            .api_key = try allocator.dupe(u8, api_key),
            .api_format = api_format,
            .base_endpoint = base_endpoint,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_model);
        self.allocator.free(self.endpoint_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_endpoint);
    }

    pub fn setModel(self: *Self, model_id: []const u8) !void {
        const new_model = try self.allocator.dupe(u8, model_id);
        self.allocator.free(self.current_model);
        self.current_model = new_model;

        // Update API format and endpoint URL for the new model
        for (AvailableModels) |model| {
            if (std.mem.eql(u8, model.id, model_id)) {
                self.api_format = model.api_format;

                // Update endpoint URL with correct path
                const new_endpoint = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                    self.base_endpoint,
                    model.endpoint_path,
                }) catch return error.OutOfMemory;

                self.allocator.free(self.endpoint_url);
                self.endpoint_url = new_endpoint;
                break;
            }
        }
    }
};

/// Parse a command from message text
pub fn parseCommand(text: []const u8) struct { command: []const u8, args: []const u8 } {
    // Remove leading slash if present
    const cmd_start: usize = if (text.len > 0 and text[0] == '/') 1 else 0;

    // Find end of command (space or end of string)
    var cmd_end: usize = cmd_start;
    while (cmd_end < text.len and text[cmd_end] != ' ') {
        cmd_end += 1;
    }

    const command = text[cmd_start..cmd_end];

    // Get arguments (everything after first space)
    const args_start: usize = if (cmd_end < text.len) cmd_end + 1 else text.len;
    const args: []const u8 = if (args_start < text.len) text[args_start..] else "";

    return .{ .command = command, .args = args };
}

/// Check if text is a command
pub fn isCommand(text: []const u8) bool {
    return text.len > 1 and text[0] == '/';
}

/// Handle /start command
pub fn handleStart(tg_client: *telegram.TelegramClient, chat_id: i64) CommandError!void {
    const welcome_message =
        \\Welcome to OpenCode Bot! 
        \\
        \\Available commands:
        \\/models - List available models
        \\/model <name> - Switch to a model
        \\/help - Show this help message
        \\
        \\Current model: see /models
    ;

    tg_client.sendMessage(chat_id, welcome_message) catch |err| {
        std.log.err("Failed to send welcome message: {s}", .{@errorName(err)});
        return CommandError.SendFailed;
    };
}

/// Handle /help command
pub fn handleHelp(tg_client: *telegram.TelegramClient, chat_id: i64) CommandError!void {
    const help_message =
        \\OpenCode Bot Commands:
        \\
        \\/models - List all available models
        \\/model <name> - Switch to a specific model
        \\/current - Show current model
        \\/help - Show this help message
        \\
        \\Simply send a message to chat with the AI!
    ;

    tg_client.sendMessage(chat_id, help_message) catch |err| {
        std.log.err("Failed to send help message: {s}", .{@errorName(err)});
        return CommandError.SendFailed;
    };
}

/// Handle /models command
pub fn handleModels(tg_client: *telegram.TelegramClient, chat_id: i64) CommandError!void {
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(std.heap.page_allocator);

    response.appendSlice(std.heap.page_allocator, "Available models:\n\n") catch {
        return CommandError.OutOfMemory;
    };

    for (AvailableModels) |model| {
        const line = std.fmt.allocPrint(std.heap.page_allocator, "• {s} ({s})\n  {s}\n\n", .{
            model.name,
            model.id,
            model.description,
        }) catch {
            return CommandError.OutOfMemory;
        };
        defer std.heap.page_allocator.free(line);

        response.appendSlice(std.heap.page_allocator, line) catch {
            return CommandError.OutOfMemory;
        };
    }

    response.appendSlice(std.heap.page_allocator, "\nUse /model <id> to switch models") catch {
        return CommandError.OutOfMemory;
    };

    tg_client.sendMessage(chat_id, response.items) catch |err| {
        std.log.err("Failed to send models list: {s}", .{@errorName(err)});
        return CommandError.SendFailed;
    };
}

/// Handle /model command to switch models
pub fn handleModel(
    tg_client: *telegram.TelegramClient,
    chat_id: i64,
    args: []const u8,
    state: *BotState,
) CommandError!void {
    if (args.len == 0) {
        // Show current model and available options
        const msg = std.fmt.allocPrint(std.heap.page_allocator,
            \\Current model: {s}
            \\
            \\Use /model <id> to switch
            \\Use /models to see available options
        , .{state.current_model}) catch {
            return CommandError.OutOfMemory;
        };
        defer std.heap.page_allocator.free(msg);

        tg_client.sendMessage(chat_id, msg) catch |err| {
            std.log.err("Failed to send current model: {s}", .{@errorName(err)});
            return CommandError.SendFailed;
        };
        return;
    }

    // Find the model
    var found = false;
    for (AvailableModels) |model| {
        if (std.mem.eql(u8, model.id, args) or std.mem.eql(u8, model.name, args)) {
            state.setModel(model.id) catch {
                return CommandError.OutOfMemory;
            };

            const msg = std.fmt.allocPrint(std.heap.page_allocator, "Switched to model: {s} ({s})", .{
                model.name,
                model.id,
            }) catch {
                return CommandError.OutOfMemory;
            };
            defer std.heap.page_allocator.free(msg);

            tg_client.sendMessage(chat_id, msg) catch |err| {
                std.log.err("Failed to send model switch confirmation: {s}", .{@errorName(err)});
                return CommandError.SendFailed;
            };

            found = true;
            break;
        }
    }

    if (!found) {
        const error_msg = std.fmt.allocPrint(std.heap.page_allocator,
            \\Unknown model: {s}
            \\
            \\Use /models to see available models
        , .{args}) catch {
            return CommandError.OutOfMemory;
        };
        defer std.heap.page_allocator.free(error_msg);

        tg_client.sendMessage(chat_id, error_msg) catch |err| {
            std.log.err("Failed to send error message: {s}", .{@errorName(err)});
            return CommandError.SendFailed;
        };
        return CommandError.InvalidArgument;
    }
}

/// Handle /current command
pub fn handleCurrent(
    tg_client: *telegram.TelegramClient,
    chat_id: i64,
    state: *BotState,
) CommandError!void {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "Current model: {s}", .{state.current_model}) catch {
        return CommandError.OutOfMemory;
    };
    defer std.heap.page_allocator.free(msg);

    tg_client.sendMessage(chat_id, msg) catch |err| {
        std.log.err("Failed to send current model: {s}", .{@errorName(err)});
        return CommandError.SendFailed;
    };
}

/// Main command dispatcher
pub fn handleCommand(
    tg_client: *telegram.TelegramClient,
    chat_id: i64,
    text: []const u8,
    state: *BotState,
) CommandError!bool {
    if (!isCommand(text)) {
        return false; // Not a command, should be handled as regular message
    }

    const parsed = parseCommand(text);
    const cmd = parsed.command;
    const args = parsed.args;

    std.log.info("Processing command: {s} with args: {s}", .{ cmd, args });

    if (std.mem.eql(u8, cmd, "start")) {
        try handleStart(tg_client, chat_id);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try handleHelp(tg_client, chat_id);
    } else if (std.mem.eql(u8, cmd, "models")) {
        try handleModels(tg_client, chat_id);
    } else if (std.mem.eql(u8, cmd, "model")) {
        try handleModel(tg_client, chat_id, args, state);
    } else if (std.mem.eql(u8, cmd, "current")) {
        try handleCurrent(tg_client, chat_id, state);
    } else {
        tg_client.sendMessage(chat_id, "Unknown command. Use /help to see available commands.") catch |err| {
            std.log.err("Failed to send unknown command message: {s}", .{@errorName(err)});
            return CommandError.SendFailed;
        };
        return CommandError.UnknownCommand;
    }

    return true; // Command was handled
}

test "parseCommand extracts command and args" {
    const result1 = parseCommand("/model kimi-k2.5");
    try std.testing.expectEqualStrings("model", result1.command);
    try std.testing.expectEqualStrings("kimi-k2.5", result1.args);

    const result2 = parseCommand("/help");
    try std.testing.expectEqualStrings("help", result2.command);
    try std.testing.expectEqualStrings("", result2.args);

    const result3 = parseCommand("/models  ");
    try std.testing.expectEqualStrings("models", result3.command);
    try std.testing.expectEqualStrings(" ", result3.args);
}

test "isCommand detects commands" {
    try std.testing.expect(isCommand("/start"));
    try std.testing.expect(isCommand("/model test"));
    try std.testing.expect(!isCommand("hello"));
    try std.testing.expect(!isCommand("/"));
    try std.testing.expect(!isCommand(""));
}
