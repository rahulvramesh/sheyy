//! Main entry point - Agent-based architecture with memory support
const std = @import("std");
const config = @import("config.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");
const commands = @import("commands.zig");
const agent = @import("agent.zig");
const AgentRegistry = @import("agent_registry.zig").AgentRegistry;
const AgentLoader = @import("agent_loader.zig").AgentLoader;
const memory = @import("memory.zig");
const MemoryStore = memory.MemoryStore;

/// Global state for the application
const AppState = struct {
    allocator: std.mem.Allocator,
    tg_client: *telegram.TelegramClient,
    llm_client: *llm.LlmClient,
    registry: *AgentRegistry,
    loader: *AgentLoader,
    memory: *MemoryStore,
    last_reload_check: i64,
};

/// Reinitialize LLM client with new model
fn reinitLlmClient(
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,
    state: *commands.BotState,
) !void {
    llm_client.deinit();
    llm_client.* = llm.LlmClient.init(
        allocator,
        state.api_key,
        state.endpoint_url,
        state.current_model,
        state.api_format,
    );
    std.log.info("LLM client reinitialized: {s} ({s})", .{
        state.current_model,
        @tagName(state.api_format),
    });
}

/// Process a message through the active agent with memory
fn processMessage(
    app_state: *AppState,
    chat_id: i64,
    user_id: i64,
    message: []const u8,
) !void {
    // Send typing indicator
    app_state.tg_client.sendTyping(chat_id) catch |err| {
        std.log.warn("Failed to send typing: {s}", .{@errorName(err)});
    };

    // Get active agent
    const active_agent = app_state.registry.getActiveAgent() orelse {
        try app_state.tg_client.sendMessage(chat_id, "No active agent. Use /agents to see available agents.");
        return;
    };

    // Add user message to memory
    try app_state.memory.addMessage(chat_id, user_id, "user", message, active_agent.info.id);

    // Get conversation context (last N messages)
    const context_messages = app_state.memory.getContext(chat_id, user_id);

    // Build message with context if available
    const message_with_context = if (context_messages) |msgs| blk: {
        // Include previous context in the message for the agent
        var context_builder: std.ArrayList(u8) = .empty;
        defer context_builder.deinit(app_state.allocator);

        // Add system prompt if exists
        if (active_agent.info.config.system_prompt) |prompt| {
            try context_builder.appendSlice(app_state.allocator, "System: ");
            try context_builder.appendSlice(app_state.allocator, prompt);
            try context_builder.appendSlice(app_state.allocator, "\n\nPrevious conversation:\n");
        }

        // Add context (excluding the last user message we just added)
        if (msgs.len > 1) {
            for (msgs[0 .. msgs.len - 1]) |msg| {
                const role_name = if (std.mem.eql(u8, msg.role, "user")) "User" else "Assistant";
                try context_builder.appendSlice(app_state.allocator, role_name);
                try context_builder.appendSlice(app_state.allocator, ": ");
                try context_builder.appendSlice(app_state.allocator, msg.content);
                try context_builder.appendSlice(app_state.allocator, "\n");
            }
        }

        try context_builder.appendSlice(app_state.allocator, "\nCurrent message:\nUser: ");
        try context_builder.appendSlice(app_state.allocator, message);

        break :blk context_builder.toOwnedSlice(app_state.allocator) catch message;
    } else message;

    defer if (context_messages != null and message_with_context.ptr != message.ptr) {
        app_state.allocator.free(message_with_context);
    };

    // Process through agent
    const response = active_agent.process(
        app_state.allocator,
        message_with_context,
        null,
    ) catch |err| {
        std.log.err("Agent processing failed: {s}", .{@errorName(err)});
        try app_state.tg_client.sendMessage(chat_id, "Sorry, I encountered an error.");
        return;
    };
    defer app_state.allocator.free(response);

    // Add assistant response to memory
    try app_state.memory.addMessage(chat_id, user_id, "assistant", response, active_agent.info.id);

    // Send response
    try app_state.tg_client.sendMessage(chat_id, response);
}

/// Handle agent commands
fn handleAgentCommand(
    app_state: *AppState,
    chat_id: i64,
    user_id: i64,
    command: []const u8,
    args: []const u8,
) !bool {
    if (std.mem.eql(u8, command, "agents")) {
        // List all agents
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(app_state.allocator);

        try response.appendSlice(app_state.allocator, "Available Agents:\n\n");

        var it = app_state.registry.agents.iterator();
        while (it.next()) |entry| {
            const ag = entry.value_ptr.agent;
            const is_active = app_state.registry.isActiveAgent(ag.info.id);
            const status_icon = if (is_active) "●" else "○";

            const line = std.fmt.allocPrint(app_state.allocator, "{s} {s} - {s}\n", .{
                status_icon,
                ag.info.name,
                ag.info.description,
            }) catch continue;
            defer app_state.allocator.free(line);

            try response.appendSlice(app_state.allocator, line);
        }

        try response.appendSlice(app_state.allocator, "\nUse /agent <name> to switch agents");
        try app_state.tg_client.sendMessage(chat_id, response.items);
        return true;
    }

    if (std.mem.eql(u8, command, "agent")) {
        // Switch to agent
        if (args.len == 0) {
            const current = app_state.registry.getActiveAgent();
            const msg = if (current) |ag|
                std.fmt.allocPrint(app_state.allocator, "Current agent: {s}", .{ag.info.name}) catch "Current agent error"
            else
                "No active agent";
            defer if (current != null) app_state.allocator.free(msg);
            try app_state.tg_client.sendMessage(chat_id, msg);
            return true;
        }

        // Try to switch to the specified agent
        if (app_state.registry.getAgent(args)) |ag| {
            try app_state.registry.setActiveAgent(args);

            // Clear conversation history when switching agents
            try app_state.memory.clearConversation(chat_id);

            const msg = std.fmt.allocPrint(app_state.allocator, "Switched to agent: {s}\n\nConversation history cleared for new agent context.", .{ag.info.name}) catch "Switch message error";
            defer app_state.allocator.free(msg);
            try app_state.tg_client.sendMessage(chat_id, msg);
        } else {
            try app_state.tg_client.sendMessage(chat_id, "Agent not found. Use /agents to see available agents.");
        }
        return true;
    }

    if (std.mem.eql(u8, command, "reload")) {
        // Reload all agents
        app_state.registry.checkAndReload();
        try app_state.tg_client.sendMessage(chat_id, "Agents reloaded successfully.");
        return true;
    }

    if (std.mem.eql(u8, command, "clear")) {
        // Clear conversation history
        try app_state.memory.clearConversation(chat_id);
        try app_state.tg_client.sendMessage(chat_id, "✅ Conversation history cleared. Starting fresh!");
        return true;
    }

    if (std.mem.eql(u8, command, "history")) {
        // Show conversation history
        const msgs = app_state.memory.getContext(chat_id, user_id);
        if (msgs) |messages| {
            var response: std.ArrayList(u8) = .empty;
            defer response.deinit(app_state.allocator);

            try response.appendSlice(app_state.allocator, "Recent conversation:\n\n");

            for (messages) |msg| {
                const role_icon = if (std.mem.eql(u8, msg.role, "user")) "👤" else "🤖";
                const line = std.fmt.allocPrint(app_state.allocator, "{s} {s}: {s}\n", .{
                    role_icon,
                    msg.role,
                    msg.content,
                }) catch continue;
                defer app_state.allocator.free(line);
                try response.appendSlice(app_state.allocator, line);
            }

            try app_state.tg_client.sendMessage(chat_id, response.items);
        } else {
            try app_state.tg_client.sendMessage(chat_id, "No conversation history yet.");
        }
        return true;
    }

    if (std.mem.eql(u8, command, "start")) {
        const welcome =
            \\Welcome to the AI Agent Bot! 🤖
            \\
            \\Commands:
            \\/agents - List all available agents
            \\/agent <name> - Switch to an agent
            \\/agent - Show current agent
            \\/clear - Clear conversation history
            \\/history - Show recent conversation
            \\/reload - Reload all agents
            \\/help - Show this help
            \\
            \\Features:
            \\✅ Multi-agent system with specialized AI assistants
            \\✅ Persistent conversation memory across sessions
            \\✅ Hot-reload agents without restart
            \\
            \\Simply send a message to chat with the active AI agent!
        ;
        try app_state.tg_client.sendMessage(chat_id, welcome);
        return true;
    }

    if (std.mem.eql(u8, command, "help")) {
        const help_text =
            \\🤖 AI Agent Bot Commands:
            \\
            \\/agents - List all available AI agents
            \\/agent <name> - Switch to a specific agent (e.g., /agent assistant)
            \\/agent - Show currently active agent
            \\/clear - Clear conversation history for this chat
            \\/history - Show recent conversation history
            \\/reload - Hot reload all agents from files
            \\/help - Show this help message
            \\/start - Show welcome message
            \\
            \\💡 The bot remembers your conversation history automatically!
            \\Use /clear to start fresh with a new context.
        ;
        try app_state.tg_client.sendMessage(chat_id, help_text);
        return true;
    }

    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    std.log.info("Starting Telegram LLM Bot with Agent Architecture + Memory...", .{});

    // Load configuration
    const auth = config.loadAuthConfig(allocator) catch |err| {
        std.log.err("Failed to load auth: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeAuthConfig(allocator, auth);

    const model_config = config.loadModelConfig(allocator) catch |err| {
        std.log.err("Failed to load models config: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeModelConfig(allocator, model_config);

    const allowed_users = config.loadAllowedUsers(allocator) catch |err| {
        std.log.err("Failed to load allowed users: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(allowed_users);

    // Initialize Telegram client
    var tg_client = try telegram.TelegramClient.init(allocator, auth.telegram_bot_token, allowed_users);
    defer tg_client.deinit();

    // Set bot commands
    tg_client.setMyCommands() catch |err| {
        std.log.warn("Failed to set commands: {s}", .{@errorName(err)});
    };

    // Initialize LLM client
    var llm_client = llm.LlmClient.init(
        allocator,
        auth.llm_api_key,
        model_config.llm_endpoint_url,
        model_config.model_name,
        .openai,
    );
    defer llm_client.deinit();

    // Initialize memory store
    var memory_store = try MemoryStore.init(allocator, "./memory", 50, true);
    defer memory_store.deinit();
    std.log.info("Memory system initialized (max history: 50 messages)", .{});

    // Initialize agent registry
    var registry = try AgentRegistry.init(allocator, "./agents", true);
    defer registry.deinit();

    // Initialize agent loader
    var loader = AgentLoader.init(allocator, &llm_client);

    // Load all agents from agents directory
    try loader.loadAllFromDirectory("./agents", &registry);

    // If no agents loaded, create default
    if (registry.agentCount() == 0) {
        std.log.info("No agents found, creating default...", .{});
        const default_agent = try loader.createBuiltInAgent(
            "default",
            "Default Assistant",
            "General purpose AI assistant",
            model_config.model_name,
            "You are a helpful AI assistant.",
        );
        try registry.registerAgent(default_agent, null);
    }

    // Set default agent (assistant) as active
    if (registry.getAgent("assistant")) |_| {
        try registry.setActiveAgent("assistant");
    } else {
        var it = registry.agents.iterator();
        if (it.next()) |entry| {
            try registry.setActiveAgent(entry.key_ptr.*);
        }
    }

    std.log.info("Bot ready with {d} agents. Active: {s}", .{
        registry.agentCount(),
        if (registry.getActiveAgent()) |ag| ag.info.name else "none",
    });

    // Create app state
    var app_state = AppState{
        .allocator = allocator,
        .tg_client = &tg_client,
        .llm_client = &llm_client,
        .registry = &registry,
        .loader = &loader,
        .memory = &memory_store,
        .last_reload_check = std.time.timestamp(),
    };

    // Main loop
    const poll_timeout: u32 = 30;

    while (true) {
        // Check for hot reload every 5 seconds
        const now = std.time.timestamp();
        if (now - app_state.last_reload_check >= 5) {
            registry.checkAndReload();
            app_state.last_reload_check = now;
        }

        // Poll for updates
        const messages = tg_client.pollUpdates(poll_timeout) catch |err| {
            std.log.err("Poll error: {s}", .{@errorName(err)});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer {
            for (messages) |msg| msg.deinit(allocator);
            allocator.free(messages);
        }

        // Process messages
        for (messages) |msg| {
            std.log.info("Message from user {d}: {s}", .{ msg.user_id, msg.text });

            // Parse command
            if (commands.isCommand(msg.text)) {
                const parsed = commands.parseCommand(msg.text);

                // Handle agent commands
                if (try handleAgentCommand(&app_state, msg.chat_id, msg.user_id, parsed.command, parsed.args)) {
                    continue;
                }

                // Unknown command
                try app_state.tg_client.sendMessage(msg.chat_id, "Unknown command. Use /help to see available commands.");
                continue;
            }

            // Process as regular message with memory
            try processMessage(&app_state, msg.chat_id, msg.user_id, msg.text);
        }

        if (messages.len == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
