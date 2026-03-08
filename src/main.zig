//! Main entry point for the Telegram-LLM bridge application
const std = @import("std");
const config = @import("config.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");
const commands = @import("commands.zig");

/// Reinitialize LLM client with new model
fn reinitLlmClient(
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,
    state: *commands.BotState,
) !void {
    // Deinit old client
    llm_client.deinit();

    // Reinit with new model and api format
    llm_client.* = llm.LlmClient.init(
        allocator,
        state.api_key,
        state.endpoint_url,
        state.current_model,
        state.api_format,
    );

    std.log.info("LLM client reinitialized with model: {s} (format: {s})", .{
        state.current_model,
        @tagName(state.api_format),
    });
}

pub fn main() !void {
    // Initialize GPA for memory tracking in debug builds
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Load configuration
    std.log.info("Loading configuration...", .{});

    const auth = config.loadAuthConfig(allocator) catch |err| {
        std.log.err("Failed to load auth configuration: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeAuthConfig(allocator, auth);

    const model_config = config.loadModelConfig(allocator) catch |err| {
        std.log.err("Failed to load model configuration: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeModelConfig(allocator, model_config);

    // Load allowed users list
    const allowed_users = config.loadAllowedUsers(allocator) catch |err| {
        std.log.err("Failed to load allowed users: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(allowed_users);

    std.log.info("Configuration loaded successfully", .{});
    std.log.info("Using model: {s}", .{model_config.model_name});
    std.log.info("LLM endpoint: {s}", .{model_config.llm_endpoint_url});

    if (allowed_users.len > 0) {
        std.log.info("Security: Only {d} authorized user(s) can access this bot", .{allowed_users.len});
    } else {
        std.log.warn("Security: No allowed_users.json found - bot is open to all users!", .{});
    }

    // Initialize Telegram client
    var tg_client = telegram.TelegramClient.init(allocator, auth.telegram_bot_token, allowed_users) catch |err| {
        std.log.err("Failed to initialize Telegram client: {s}", .{@errorName(err)});
        return err;
    };
    defer tg_client.deinit();

    std.log.info("Telegram client initialized", .{});

    // Register bot commands menu
    tg_client.setMyCommands() catch |err| {
        std.log.warn("Failed to set bot commands menu: {s}", .{@errorName(err)});
        // Continue anyway, this is not critical
    };

    // Initialize bot state
    var bot_state = try commands.BotState.init(
        allocator,
        model_config.model_name,
        model_config.llm_endpoint_url,
        auth.llm_api_key,
    );
    defer bot_state.deinit();

    // Initialize LLM client
    var llm_client = llm.LlmClient.init(
        allocator,
        auth.llm_api_key,
        bot_state.endpoint_url,
        bot_state.current_model,
        bot_state.api_format,
    );
    defer llm_client.deinit();

    std.log.info("LLM client initialized", .{});
    std.log.info("Starting message polling loop...", .{});
    std.log.info("Bot commands available: /start, /help, /models, /model <name>, /current", .{});

    // Main polling loop
    const poll_timeout: u32 = 30; // 30 seconds timeout for long polling

    while (true) {
        // Poll for updates from Telegram
        const messages = tg_client.pollUpdates(poll_timeout) catch |err| {
            std.log.err("Error polling updates: {s}", .{@errorName(err)});
            std.Thread.sleep(5 * std.time.ns_per_s); // Wait 5 seconds before retrying
            continue;
        };
        defer {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Process each message
        for (messages) |msg| {
            std.log.info("Received message from user {d} in chat {d}: {s}", .{ msg.user_id, msg.chat_id, msg.text });

            // Check if it's a command
            if (commands.isCommand(msg.text)) {
                const old_model = bot_state.current_model;

                const handled = commands.handleCommand(&tg_client, msg.chat_id, msg.text, &bot_state) catch |err| {
                    std.log.err("Failed to handle command: {s}", .{@errorName(err)});
                    continue;
                };

                if (handled) {
                    // Check if model was changed
                    if (!std.mem.eql(u8, old_model, bot_state.current_model)) {
                        std.log.info("Model changed from {s} to {s}", .{ old_model, bot_state.current_model });

                        // Reinitialize LLM client with new model
                        reinitLlmClient(allocator, &llm_client, &bot_state) catch |err| {
                            std.log.err("Failed to reinitialize LLM client: {s}", .{@errorName(err)});

                            // Revert to old model on error
                            bot_state.setModel(old_model) catch {};
                            tg_client.sendMessage(msg.chat_id, "Failed to switch model. Reverted to previous model.") catch {};
                        };
                    }
                    continue; // Command handled, don't process as chat message
                }
            }

            // Not a command, process as regular chat message

            // Send typing indicator to show the bot is processing
            tg_client.sendTyping(msg.chat_id) catch |err| {
                std.log.warn("Failed to send typing indicator: {s}", .{@errorName(err)});
                // Continue processing even if typing indicator fails
            };

            // Get response from LLM (non-streaming)
            const llm_response = llm_client.chatCompletion(msg.text) catch |err| {
                std.log.err("Error getting LLM response: {s}", .{@errorName(err)});

                // Send error message to user
                tg_client.sendMessage(msg.chat_id, "Sorry, I encountered an error processing your request. Please try again later.") catch |send_err| {
                    std.log.err("Failed to send error message: {s}", .{@errorName(send_err)});
                };
                continue;
            };
            defer allocator.free(llm_response);

            std.log.info("LLM response: {s}", .{llm_response});

            // Send response back to Telegram
            tg_client.sendMessage(msg.chat_id, llm_response) catch |err| {
                std.log.err("Failed to send message: {s}", .{@errorName(err)});
            };
        }

        // Small delay to prevent tight looping when no messages
        if (messages.len == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms
        }
    }
}
