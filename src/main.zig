//! Personal AI Assistant Bot - Telegram + Multi-LLM Agent Architecture
const std = @import("std");
const config = @import("config.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");

// ── Agent Definition ──────────────────────────────────────────────

const AgentDef = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    model_id: []const u8,
    temperature: f32,
    api_format: llm.ApiFormat,
    source_path: ?[]const u8, // for hot reload
    last_modified: ?i128,
};

/// JSON shape matching agents/*.json files
const AgentJson = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    config: struct {
        model_id: []const u8,
        system_prompt: ?[]const u8 = null,
        temperature: f32 = 0.7,
        max_tokens: i32 = 4096,
    },
};

/// Determine API format from model ID
fn apiFormatForModel(model_id: []const u8) llm.ApiFormat {
    // Models that use Anthropic format
    if (std.mem.startsWith(u8, model_id, "claude")) return .anthropic;
    if (std.mem.startsWith(u8, model_id, "minimax")) return .anthropic;
    return .openai;
}

/// Load a single agent from a JSON file, returns owned AgentDef
fn loadAgent(allocator: std.mem.Allocator, file_path: []const u8) !*AgentDef {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(AgentJson, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const def = try allocator.create(AgentDef);
    errdefer allocator.destroy(def);

    const v = parsed.value;
    def.* = .{
        .id = try allocator.dupe(u8, v.id),
        .name = try allocator.dupe(u8, v.name),
        .description = try allocator.dupe(u8, v.description),
        .system_prompt = if (v.config.system_prompt) |p| try allocator.dupe(u8, p) else try allocator.dupe(u8, "You are a helpful assistant."),
        .model_id = try allocator.dupe(u8, v.config.model_id),
        .temperature = v.config.temperature,
        .api_format = apiFormatForModel(v.config.model_id),
        .source_path = try allocator.dupe(u8, file_path),
        .last_modified = getFileMtime(file_path) catch null,
    };
    return def;
}

fn freeAgent(allocator: std.mem.Allocator, def: *AgentDef) void {
    allocator.free(def.id);
    allocator.free(def.name);
    allocator.free(def.description);
    allocator.free(def.system_prompt);
    allocator.free(def.model_id);
    if (def.source_path) |p| allocator.free(p);
    allocator.destroy(def);
}

fn getFileMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

/// Load all agents from a directory
fn loadAllAgents(allocator: std.mem.Allocator, dir_path: []const u8) !std.StringHashMap(*AgentDef) {
    var agents = std.StringHashMap(*AgentDef).init(allocator);
    errdefer agents.deinit();

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Cannot open agents dir {s}: {s}", .{ dir_path, @errorName(err) });
        return agents;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        const agent_def = loadAgent(allocator, full_path) catch |err| {
            std.log.err("Failed to load {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };

        agents.put(agent_def.id, agent_def) catch |err| {
            std.log.err("Failed to register {s}: {s}", .{ agent_def.id, @errorName(err) });
            freeAgent(allocator, agent_def);
            continue;
        };

        std.log.info("Loaded agent: {s} ({s})", .{ agent_def.name, agent_def.id });
    }

    return agents;
}

// ── Conversation Memory ───────────────────────────────────────────

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const Conversation = struct {
    messages: std.ArrayList(OwnedMessage),

    const OwnedMessage = struct {
        role: []const u8,
        content: []const u8,

        fn deinit(self: OwnedMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.role);
            allocator.free(self.content);
        }
    };

    fn init() Conversation {
        return .{ .messages = .empty };
    }

    fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages.items) |msg| msg.deinit(allocator);
        self.messages.deinit(allocator);
    }

    fn addMessage(self: *Conversation, allocator: std.mem.Allocator, role: []const u8, content: []const u8) !void {
        try self.messages.append(allocator, .{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
        });
    }

    fn clear(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages.items) |msg| msg.deinit(allocator);
        self.messages.clearRetainingCapacity();
    }

    /// Trim to keep only last `max` messages
    fn trim(self: *Conversation, allocator: std.mem.Allocator, max: usize) void {
        if (self.messages.items.len <= max) return;
        const to_remove = self.messages.items.len - max;
        for (self.messages.items[0..to_remove]) |msg| msg.deinit(allocator);
        // Shift remaining
        std.mem.copyForwards(
            Conversation.OwnedMessage,
            self.messages.items[0..max],
            self.messages.items[to_remove..],
        );
        self.messages.shrinkRetainingCapacity(max);
    }
};

/// JSON shape for persisted conversations
const SavedMessage = struct {
    role: []const u8,
    content: []const u8,
};

const SavedConversation = struct {
    chat_id: i64,
    messages: []const SavedMessage,
};

fn saveConversation(allocator: std.mem.Allocator, persist_dir: []const u8, chat_id: i64, conv: *const Conversation) void {
    // Build the serializable structure
    const msgs = allocator.alloc(SavedMessage, conv.messages.items.len) catch return;
    defer allocator.free(msgs);

    for (conv.messages.items, 0..) |msg, i| {
        msgs[i] = .{ .role = msg.role, .content = msg.content };
    }

    const saved = SavedConversation{
        .chat_id = chat_id,
        .messages = msgs,
    };

    const json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(saved, .{ .whitespace = .indent_2 })}) catch return;
    defer allocator.free(json);

    const filename = std.fmt.allocPrint(allocator, "{s}/chat_{d}.json", .{ persist_dir, chat_id }) catch return;
    defer allocator.free(filename);

    std.fs.cwd().writeFile(.{ .sub_path = filename, .data = json }) catch |err| {
        std.log.warn("Failed to save conversation: {s}", .{@errorName(err)});
    };
}

fn loadConversation(allocator: std.mem.Allocator, persist_dir: []const u8, chat_id: i64) ?Conversation {
    const filename = std.fmt.allocPrint(allocator, "{s}/chat_{d}.json", .{ persist_dir, chat_id }) catch return null;
    defer allocator.free(filename);

    const content = std.fs.cwd().readFileAlloc(allocator, filename, 10 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(SavedConversation, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var conv = Conversation.init();
    for (parsed.value.messages) |msg| {
        conv.addMessage(allocator, msg.role, msg.content) catch {
            conv.deinit(allocator);
            return null;
        };
    }
    return conv;
}

// ── Application State ─────────────────────────────────────────────

const AppState = struct {
    allocator: std.mem.Allocator,
    tg: *telegram.TelegramClient,
    llm_client: *llm.LlmClient,
    agents: std.StringHashMap(*AgentDef),
    active_agent_id: ?[]const u8,
    conversations: std.AutoHashMap(i64, Conversation),
    persist_dir: []const u8,
    max_history: usize,
    max_context: usize,
    last_reload_check: i64,

    fn getActiveAgent(self: *AppState) ?*AgentDef {
        const id = self.active_agent_id orelse return null;
        return self.agents.get(id);
    }

    fn setActiveAgent(self: *AppState, id: []const u8) !void {
        if (!self.agents.contains(id)) return error.AgentNotFound;
        if (self.active_agent_id) |old| self.allocator.free(old);
        self.active_agent_id = try self.allocator.dupe(u8, id);
    }

    fn getOrCreateConv(self: *AppState, chat_id: i64) !*Conversation {
        const result = try self.conversations.getOrPut(chat_id);
        if (!result.found_existing) {
            // Try loading from disk
            if (loadConversation(self.allocator, self.persist_dir, chat_id)) |loaded| {
                result.value_ptr.* = loaded;
            } else {
                result.value_ptr.* = Conversation.init();
            }
        }
        return result.value_ptr;
    }
};

// ── Message Processing ────────────────────────────────────────────

fn processMessage(state: *AppState, chat_id: i64, text: []const u8) void {
    // Send typing indicator
    state.tg.sendTyping(chat_id) catch {};

    const agent_def = state.getActiveAgent() orelse {
        state.tg.sendMessage(chat_id, "No active agent. Use /agents to list agents.") catch {};
        return;
    };

    // Get or create conversation
    const conv = state.getOrCreateConv(chat_id) catch {
        state.tg.sendMessage(chat_id, "Memory error.") catch {};
        return;
    };

    // Add user message to history
    conv.addMessage(state.allocator, "user", text) catch return;

    // Trim if too long
    conv.trim(state.allocator, state.max_history);

    // Build messages array for LLM: system + conversation history
    const msg_count = conv.messages.items.len + 1; // +1 for system
    const api_messages = state.allocator.alloc(llm.ChatMessage, msg_count) catch return;
    defer state.allocator.free(api_messages);

    // System prompt
    api_messages[0] = .{ .role = "system", .content = agent_def.system_prompt };

    // Conversation history (last max_context messages)
    const items = conv.messages.items;
    const start = if (items.len > state.max_context) items.len - state.max_context else 0;
    const context_msgs = items[start..];

    const final_messages = state.allocator.alloc(llm.ChatMessage, 1 + context_msgs.len) catch return;
    defer state.allocator.free(final_messages);

    final_messages[0] = .{ .role = "system", .content = agent_def.system_prompt };
    for (context_msgs, 1..) |msg, i| {
        final_messages[i] = .{ .role = msg.role, .content = msg.content };
    }

    // Call LLM
    const response = state.llm_client.chatCompletion(
        final_messages,
        agent_def.model_id,
        agent_def.temperature,
        agent_def.api_format,
    ) catch |err| {
        std.log.err("LLM error: {s}", .{@errorName(err)});
        state.tg.sendMessage(chat_id, "Sorry, the AI service returned an error. Please try again.") catch {};
        return;
    };
    defer state.allocator.free(response);

    // Add assistant response to history
    conv.addMessage(state.allocator, "assistant", response) catch {};

    // Persist conversation
    saveConversation(state.allocator, state.persist_dir, chat_id, conv);

    // Send response (auto-splits if >4096 chars)
    state.tg.sendMessage(chat_id, response) catch |err| {
        std.log.err("Send failed: {s}", .{@errorName(err)});
    };
}

// ── Command Handling ──────────────────────────────────────────────

fn isCommand(text: []const u8) bool {
    return text.len > 1 and text[0] == '/';
}

fn parseCommand(text: []const u8) struct { cmd: []const u8, args: []const u8 } {
    const start: usize = if (text[0] == '/') 1 else 0;
    var end = start;
    while (end < text.len and text[end] != ' ') end += 1;
    const args_start = if (end < text.len) end + 1 else text.len;
    return .{
        .cmd = text[start..end],
        .args = if (args_start < text.len) text[args_start..] else "",
    };
}

fn handleCommand(state: *AppState, chat_id: i64, text: []const u8) void {
    const parsed = parseCommand(text);
    const cmd = parsed.cmd;
    const args = parsed.args;

    if (std.mem.eql(u8, cmd, "start") or std.mem.eql(u8, cmd, "help")) {
        state.tg.sendMessage(chat_id,
            \\AI Agent Bot
            \\
            \\Commands:
            \\/agents - List available agents
            \\/agent <name> - Switch agent
            \\/clear - Clear conversation
            \\/history - Show recent messages
            \\/reload - Reload agent configs
            \\/help - Show this message
            \\
            \\Send any message to chat with the active agent!
        ) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "agents")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Available Agents:\n\n", .{}) catch return;

        var it = state.agents.iterator();
        while (it.next()) |entry| {
            const ag = entry.value_ptr.*;
            const active = if (state.active_agent_id) |aid| std.mem.eql(u8, aid, ag.id) else false;
            const icon: []const u8 = if (active) ">" else " ";
            w.print("{s} {s} - {s}\n", .{ icon, ag.name, ag.description }) catch continue;
        }
        w.print("\nUse /agent <id> to switch", .{}) catch {};
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "agent")) {
        if (args.len == 0) {
            if (state.getActiveAgent()) |ag| {
                const msg = std.fmt.allocPrint(state.allocator, "Active agent: {s} ({s})\nModel: {s}", .{ ag.name, ag.id, ag.model_id }) catch return;
                defer state.allocator.free(msg);
                state.tg.sendMessage(chat_id, msg) catch {};
            } else {
                state.tg.sendMessage(chat_id, "No active agent.") catch {};
            }
            return;
        }

        if (state.agents.contains(args)) {
            state.setActiveAgent(args) catch return;

            // Clear conversation on agent switch
            if (state.conversations.getPtr(chat_id)) |conv| {
                conv.clear(state.allocator);
            }

            const msg = std.fmt.allocPrint(state.allocator, "Switched to: {s}. Conversation cleared.", .{args}) catch return;
            defer state.allocator.free(msg);
            state.tg.sendMessage(chat_id, msg) catch {};
        } else {
            state.tg.sendMessage(chat_id, "Agent not found. Use /agents to see available agents.") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "clear")) {
        if (state.conversations.getPtr(chat_id)) |conv| {
            conv.clear(state.allocator);
        }
        // Delete persisted file
        const filename = std.fmt.allocPrint(state.allocator, "{s}/chat_{d}.json", .{ state.persist_dir, chat_id }) catch return;
        defer state.allocator.free(filename);
        std.fs.cwd().deleteFile(filename) catch {};

        state.tg.sendMessage(chat_id, "Conversation cleared.") catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "history")) {
        const conv = state.conversations.get(chat_id) orelse {
            state.tg.sendMessage(chat_id, "No conversation history.") catch {};
            return;
        };

        if (conv.messages.items.len == 0) {
            state.tg.sendMessage(chat_id, "No conversation history.") catch {};
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Recent conversation ({d} messages):\n\n", .{conv.messages.items.len}) catch return;
        // Show last 10
        const items = conv.messages.items;
        const start = if (items.len > 10) items.len - 10 else 0;
        for (items[start..]) |msg| {
            const label: []const u8 = if (std.mem.eql(u8, msg.role, "user")) "You" else "AI";
            // Truncate long messages in history view
            const preview = if (msg.content.len > 200) msg.content[0..200] else msg.content;
            w.print("{s}: {s}", .{ label, preview }) catch continue;
            if (msg.content.len > 200) w.print("...", .{}) catch {};
            w.print("\n\n", .{}) catch {};
        }
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "reload")) {
        reloadAgents(state);
        state.tg.sendMessage(chat_id, "Agents reloaded.") catch {};
        return;
    }

    state.tg.sendMessage(chat_id, "Unknown command. Use /help.") catch {};
}

// ── Hot Reload ────────────────────────────────────────────────────

fn reloadAgents(state: *AppState) void {
    var it = state.agents.iterator();
    while (it.next()) |entry| {
        const ag = entry.value_ptr.*;
        const path = ag.source_path orelse continue;

        const current_mtime = getFileMtime(path) catch continue;
        const last_mtime = ag.last_modified orelse current_mtime;

        if (current_mtime > last_mtime) {
            std.log.info("Reloading agent: {s}", .{ag.id});

            const new_agent = loadAgent(state.allocator, path) catch |err| {
                std.log.err("Reload failed for {s}: {s}", .{ ag.id, @errorName(err) });
                continue;
            };

            // Replace in map
            freeAgent(state.allocator, ag);
            entry.value_ptr.* = new_agent;
        }
    }
}

// ── Entry Point ───────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) std.log.err("Memory leak detected!", .{});
    }
    const allocator = gpa.allocator();

    std.log.info("Starting AI Agent Bot...", .{});

    // Load configs
    const auth = config.loadAuthConfig(allocator) catch |err| {
        std.log.err("Failed to load auth.json: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeAuthConfig(allocator, auth);

    const model_config = config.loadModelConfig(allocator) catch |err| {
        std.log.err("Failed to load models.json: {s}", .{@errorName(err)});
        return err;
    };
    defer config.freeModelConfig(allocator, model_config);

    const allowed_users = config.loadAllowedUsers(allocator) catch |err| {
        std.log.err("Failed to load allowed_users.json: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(allowed_users);

    // Initialize Telegram
    var tg_client = try telegram.TelegramClient.init(allocator, auth.telegram_bot_token, allowed_users);
    defer tg_client.deinit();

    tg_client.setMyCommands() catch |err| {
        std.log.warn("Failed to set commands: {s}", .{@errorName(err)});
    };

    // Initialize LLM client
    var llm_client = llm.LlmClient.init(allocator, auth.llm_api_key, model_config.llm_endpoint_url);
    defer llm_client.deinit();

    // Create memory persist directory
    const persist_dir = "./memory";
    std.fs.cwd().makePath(persist_dir) catch {};

    // Load agents
    var agents = try loadAllAgents(allocator, "./agents");
    defer {
        var it = agents.iterator();
        while (it.next()) |entry| freeAgent(allocator, entry.value_ptr.*);
        agents.deinit();
    }

    if (agents.count() == 0) {
        std.log.warn("No agents found in ./agents/", .{});
    }

    // App state
    var state = AppState{
        .allocator = allocator,
        .tg = &tg_client,
        .llm_client = &llm_client,
        .agents = agents,
        .active_agent_id = null,
        .conversations = std.AutoHashMap(i64, Conversation).init(allocator),
        .persist_dir = persist_dir,
        .max_history = 50,
        .max_context = 20,
        .last_reload_check = std.time.timestamp(),
    };
    defer {
        var conv_it = state.conversations.iterator();
        while (conv_it.next()) |entry| entry.value_ptr.deinit(allocator);
        state.conversations.deinit();
        if (state.active_agent_id) |id| allocator.free(id);
    }

    // Set default active agent
    if (agents.get("assistant")) |_| {
        try state.setActiveAgent("assistant");
    } else {
        var it = agents.iterator();
        if (it.next()) |entry| {
            try state.setActiveAgent(entry.key_ptr.*);
        }
    }

    std.log.info("Bot ready with {d} agents. Active: {s}", .{
        agents.count(),
        if (state.getActiveAgent()) |ag| ag.name else "none",
    });

    // Main polling loop
    while (true) {
        // Hot reload check every 5 seconds
        const now = std.time.timestamp();
        if (now - state.last_reload_check >= 5) {
            reloadAgents(&state);
            state.last_reload_check = now;
        }

        const messages = tg_client.pollUpdates(30) catch |err| {
            std.log.err("Poll error: {s}", .{@errorName(err)});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer {
            for (messages) |msg| msg.deinit(allocator);
            allocator.free(messages);
        }

        for (messages) |msg| {
            std.log.info("Message from {d}", .{msg.user_id});

            if (isCommand(msg.text)) {
                handleCommand(&state, msg.chat_id, msg.text);
            } else {
                processMessage(&state, msg.chat_id, msg.text);
            }
        }

        if (messages.len == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
