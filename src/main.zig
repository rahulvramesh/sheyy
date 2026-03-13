//! Personal AI Assistant Bot - Multi-Agent Orchestration System
const std = @import("std");
const config = @import("config.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const conversation = @import("conversation.zig");
const agent_mod = @import("agent.zig");
const team_mod = @import("team.zig");
const orchestrator_mod = @import("orchestrator.zig");
const mcp = @import("mcp.zig");
const memory_cortex = @import("memory_cortex.zig");

// ── Per-Chat State ────────────────────────────────────────────────

const ChatMode = enum {
    direct_agent, // chatting with a single agent
    team_task, // orchestrator managing a team task
};

const ChatState = struct {
    mode: ChatMode,
    active_agent_id: ?[]const u8,
    active_team_id: ?[]const u8,

    fn deinit(self: *ChatState, allocator: std.mem.Allocator) void {
        if (self.active_agent_id) |id| allocator.free(id);
        if (self.active_team_id) |id| allocator.free(id);
    }
};

// ── Application State ─────────────────────────────────────────────

const AppState = struct {
    allocator: std.mem.Allocator,
    tg: *telegram.TelegramClient,
    llm_client: *llm.LlmClient,
    agents: std.StringHashMap(*agent_mod.AgentDef),
    teams: std.StringHashMap(*team_mod.TeamDef),
    tool_registry: *tools_mod.ToolRegistry,
    runtime: *agent_mod.AgentRuntime,
    orchestrator: *orchestrator_mod.Orchestrator,
    chat_states: std.AutoHashMap(i64, ChatState),
    conversations: std.AutoHashMap(i64, conversation.Conversation),
    cortex: *memory_cortex.MemoryCortex,
    work_dir: []const u8, // base working directory
    persist_dir: []const u8, // memory persistence dir
    max_history: usize,
    max_context: usize,
    last_reload_check: i64,

    fn getActiveAgent(self: *AppState, chat_id: i64) ?*agent_mod.AgentDef {
        const cs = self.chat_states.get(chat_id) orelse return null;
        const id = cs.active_agent_id orelse return null;
        return self.agents.get(id);
    }

    fn setActiveAgent(self: *AppState, chat_id: i64, agent_id: []const u8) !void {
        if (!self.agents.contains(agent_id)) return error.AgentNotFound;
        const result = try self.chat_states.getOrPut(chat_id);
        if (result.found_existing) {
            if (result.value_ptr.active_agent_id) |old| self.allocator.free(old);
        } else {
            result.value_ptr.* = .{ .mode = .direct_agent, .active_agent_id = null, .active_team_id = null };
        }
        result.value_ptr.active_agent_id = try self.allocator.dupe(u8, agent_id);
        result.value_ptr.mode = .direct_agent;
    }

    fn getOrCreateConv(self: *AppState, chat_id: i64) !*conversation.Conversation {
        const result = try self.conversations.getOrPut(chat_id);
        if (!result.found_existing) {
            if (conversation.loadConversation(self.allocator, self.persist_dir, chat_id)) |loaded| {
                result.value_ptr.* = loaded;
            } else {
                result.value_ptr.* = conversation.Conversation.init();
            }
        }
        return result.value_ptr;
    }

    fn getChatState(self: *AppState, chat_id: i64) !*ChatState {
        const result = try self.chat_states.getOrPut(chat_id);
        if (!result.found_existing) {
            result.value_ptr.* = .{ .mode = .direct_agent, .active_agent_id = null, .active_team_id = null };
        }
        return result.value_ptr;
    }
};

// ── Message Processing ────────────────────────────────────────────

fn processMessage(state: *AppState, chat_id: i64, text: []const u8) void {
    const cs = state.chat_states.get(chat_id);

    // Check if there's an active orchestrator session
    if (cs != null and cs.?.mode == .team_task) {
        if (state.orchestrator.getSession(chat_id)) |session| {
            state.orchestrator.handleMessage(session, text) catch |err| {
                std.log.err("Orchestrator error: {s}", .{@errorName(err)});
                state.tg.sendMessage(chat_id, "Error processing task.") catch {};
            };
            return;
        }
    }

    // Direct agent mode
    state.tg.sendTyping(chat_id) catch {};

    const agent_def = state.getActiveAgent(chat_id) orelse {
        state.tg.sendMessage(chat_id, "No active agent. Use /agents to list agents.") catch {};
        return;
    };

    const conv = state.getOrCreateConv(chat_id) catch {
        state.tg.sendMessage(chat_id, "Memory error.") catch {};
        return;
    };

    conv.addMessage(state.allocator, "user", text) catch return;
    conv.trim(state.allocator, state.max_history);

    // Check if agent has tools -> use AgentRuntime, else simple LLM
    if (agent_def.tool_names.len > 0) {
        // Agentic mode with tool-use loop
        const progress_id = state.tg.sendMessageReturningId(chat_id, "Thinking...") catch 0;
        const progress = if (progress_id != 0) progress_id else null;

        const response = state.runtime.run(
            agent_def,
            conv,
            chat_id,
            progress,
            null, // no specific working dir for direct chat
        ) catch |err| {
            std.log.err("Agent runtime error: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Sorry, something went wrong. Please try again.") catch {};
            return;
        };
        defer state.allocator.free(response);

        conv.addMessage(state.allocator, "assistant", response) catch {};
        conversation.saveConversation(state.allocator, state.persist_dir, chat_id, conv);

        // Edit the progress message with the response, or send new if too long
        if (progress) |pid| {
            if (response.len <= 4096) {
                state.tg.editMessage(chat_id, pid, response) catch {
                    state.tg.sendMessage(chat_id, response) catch {};
                };
            } else {
                state.tg.editMessage(chat_id, pid, "Done! See response below:") catch {};
                state.tg.sendMessage(chat_id, response) catch {};
            }
        } else {
            state.tg.sendMessage(chat_id, response) catch {};
        }
    } else {
        // Simple LLM mode (no tools) - backward compatible
        const msg_count = conv.messages.items.len + 1;
        const items = conv.messages.items;
        const start = if (items.len > state.max_context) items.len - state.max_context else 0;
        const context_msgs = items[start..];

        const final_messages = state.allocator.alloc(llm.ChatMessage, 1 + context_msgs.len) catch return;
        defer state.allocator.free(final_messages);
        _ = msg_count;

        final_messages[0] = .{ .role = "system", .content = agent_def.system_prompt };
        for (context_msgs, 1..) |msg, i| {
            final_messages[i] = .{ .role = msg.role, .content = msg.content orelse "" };
        }

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

        conv.addMessage(state.allocator, "assistant", response) catch {};
        conversation.saveConversation(state.allocator, state.persist_dir, chat_id, conv);

        state.tg.sendMessage(chat_id, response) catch |err| {
            std.log.err("Send failed: {s}", .{@errorName(err)});
        };
    }
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
            \\Agent Commands:
            \\/agents - List available agents
            \\/agent <id> - Switch agent
            \\
            \\Team Commands:
            \\/teams - List available teams
            \\/team <id> <task> - Start a team task
            \\/task - Show current task status
            \\/cancel - Cancel current task
            \\
            \\Memory:
            \\/memory add <text> - Store a memory
            \\/memory search <query> - Search memories
            \\/memory stats - Show memory stats
            \\/memory clear - Clear all memories
            \\/memory delete <id> - Delete a memory
            \\
            \\General:
            \\/clear - Clear conversation
            \\/history - Show recent messages
            \\/reload - Reload configs from disk
            \\/help - Show this message
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
            const cs = state.chat_states.get(chat_id);
            const active = if (cs) |s| (if (s.active_agent_id) |aid| std.mem.eql(u8, aid, ag.id) else false) else false;
            const icon: []const u8 = if (active) ">" else " ";
            const tool_info: []const u8 = if (ag.tool_names.len > 0) " [has tools]" else "";
            w.print("{s} {s} - {s}{s}\n", .{ icon, ag.name, ag.description, tool_info }) catch continue;
        }
        w.print("\nUse /agent <id> to switch", .{}) catch {};
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "agent")) {
        if (args.len == 0) {
            if (state.getActiveAgent(chat_id)) |ag| {
                const tool_info = if (ag.tool_names.len > 0) " (with tools)" else "";
                const msg = std.fmt.allocPrint(state.allocator, "Active agent: {s} ({s})\nModel: {s}{s}", .{ ag.name, ag.id, ag.model_id, tool_info }) catch return;
                defer state.allocator.free(msg);
                state.tg.sendMessage(chat_id, msg) catch {};
            } else {
                state.tg.sendMessage(chat_id, "No active agent.") catch {};
            }
            return;
        }

        if (state.agents.contains(args)) {
            state.setActiveAgent(chat_id, args) catch return;
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

    if (std.mem.eql(u8, cmd, "teams")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Available Teams:\n\n", .{}) catch return;

        if (state.teams.count() == 0) {
            w.print("No teams configured. Add team JSON files to the teams/ directory.", .{}) catch {};
        } else {
            var it = state.teams.iterator();
            while (it.next()) |entry| {
                const tm = entry.value_ptr.*;
                w.print("  {s} - {s} ({d} roles)\n", .{ tm.id, tm.description, tm.roles.len }) catch continue;
            }
            w.print("\nUse /team <id> <task description> to start a team task", .{}) catch {};
        }
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "team")) {
        if (args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /team <team_id> <task description>") catch {};
            return;
        }

        // Parse: first word is team_id, rest is the task
        var split_iter = std.mem.splitScalar(u8, args, ' ');
        const team_id = split_iter.next() orelse {
            state.tg.sendMessage(chat_id, "Usage: /team <team_id> <task description>") catch {};
            return;
        };

        const team_def = state.teams.get(team_id) orelse {
            const msg = std.fmt.allocPrint(state.allocator, "Team '{s}' not found. Use /teams to see available teams.", .{team_id}) catch return;
            defer state.allocator.free(msg);
            state.tg.sendMessage(chat_id, msg) catch {};
            return;
        };

        const task_desc = split_iter.rest();
        if (task_desc.len == 0) {
            state.tg.sendMessage(chat_id, "Please provide a task description: /team <id> <what you want done>") catch {};
            return;
        }

        // Set chat mode to team
        const cs = state.getChatState(chat_id) catch return;
        cs.mode = .team_task;
        if (cs.active_team_id) |old| state.allocator.free(old);
        cs.active_team_id = state.allocator.dupe(u8, team_id) catch return;

        // Start the orchestrator
        state.orchestrator.startTask(chat_id, team_def, task_desc) catch |err| {
            std.log.err("Failed to start task: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Failed to start task.") catch {};
        };
        return;
    }

    if (std.mem.eql(u8, cmd, "task")) {
        if (state.orchestrator.getSession(chat_id)) |session| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(state.allocator);
            const w = buf.writer(state.allocator);

            w.print("Task Status: {s}\n", .{@tagName(session.state)}) catch return;
            w.print("Team: {s}\n\n", .{session.team.name}) catch {};

            if (session.subtasks.items.len > 0) {
                w.print("Subtasks:\n", .{}) catch {};
                for (session.subtasks.items) |subtask| {
                    const icon: []const u8 = switch (subtask.state) {
                        .pending => "[ ]",
                        .in_progress => "[..]",
                        .completed => "[ok]",
                        .failed => "[!!]",
                    };
                    w.print("  {s} {s}\n", .{ icon, subtask.title }) catch continue;
                }
            }
            state.tg.sendMessage(chat_id, buf.items) catch {};
        } else {
            state.tg.sendMessage(chat_id, "No active task. Use /team <id> <description> to start one.") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "cancel")) {
        state.orchestrator.cancelTask(chat_id);
        const cs = state.getChatState(chat_id) catch return;
        cs.mode = .direct_agent;
        return;
    }

    if (std.mem.eql(u8, cmd, "clear")) {
        if (state.conversations.getPtr(chat_id)) |conv| {
            conv.clear(state.allocator);
        }
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
        const items = conv.messages.items;
        const start = if (items.len > 10) items.len - 10 else 0;
        for (items[start..]) |msg| {
            if (std.mem.eql(u8, msg.role, "tool")) continue; // skip tool messages in history view
            const label: []const u8 = if (std.mem.eql(u8, msg.role, "user")) "You" else "AI";
            const content = msg.content orelse "(tool call)";
            const preview = if (content.len > 200) content[0..200] else content;
            w.print("{s}: {s}", .{ label, preview }) catch continue;
            if (content.len > 200) w.print("...", .{}) catch {};
            w.print("\n\n", .{}) catch {};
        }
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "reload")) {
        agent_mod.reloadAgents(state.allocator, &state.agents);
        state.tg.sendMessage(chat_id, "Configs reloaded.") catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "memory")) {
        handleMemoryCommand(state, chat_id, args);
        return;
    }

    state.tg.sendMessage(chat_id, "Unknown command. Use /help.") catch {};
}

// ── Memory Command ────────────────────────────────────────────────

fn handleMemoryCommand(state: *AppState, chat_id: i64, args: []const u8) void {
    if (args.len == 0) {
        state.tg.sendMessage(chat_id,
            \\Usage:
            \\/memory add <text> - Store a memory (use #tags)
            \\/memory search <query> - Search memories
            \\/memory stats - Show memory statistics
            \\/memory clear - Clear all memories
            \\/memory delete <id> - Delete a memory by ID
        ) catch {};
        return;
    }

    // Parse subcommand
    var split_iter = std.mem.splitScalar(u8, args, ' ');
    const subcmd = split_iter.next() orelse "";
    const sub_args = split_iter.rest();

    if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory add <text to remember>") catch {};
            return;
        }
        state.cortex.add(sub_args, "user", &.{}) catch {
            state.tg.sendMessage(chat_id, "Failed to save memory.") catch {};
            return;
        };
        const msg = std.fmt.allocPrint(state.allocator, "Memory saved. (ID: {d})", .{state.cortex.next_id - 1}) catch return;
        defer state.allocator.free(msg);
        state.tg.sendMessage(chat_id, msg) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "search")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory search <query>") catch {};
            return;
        }
        const results = state.cortex.search(sub_args) catch {
            state.tg.sendMessage(chat_id, "Search failed.") catch {};
            return;
        };
        defer state.allocator.free(results);

        if (results.len == 0) {
            state.tg.sendMessage(chat_id, "No memories found.") catch {};
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Found {d} memor{s}:\n\n", .{ results.len, if (results.len == 1) "y" else "ies" }) catch return;

        const show = @min(results.len, 10);
        for (results[0..show]) |entry| {
            const preview = if (entry.content.len > 150) entry.content[0..150] else entry.content;
            w.print("[{d}] {s}", .{ entry.id, preview }) catch continue;
            if (entry.content.len > 150) w.print("...", .{}) catch {};
            if (entry.tags.len > 0) {
                w.print("\n  Tags:", .{}) catch {};
                for (entry.tags) |tag| {
                    w.print(" #{s}", .{tag}) catch {};
                }
            }
            w.print("\n\n", .{}) catch {};
        }

        if (results.len > 10) {
            w.print("... and {d} more.", .{results.len - 10}) catch {};
        }

        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "stats")) {
        const result = state.cortex.stats() catch {
            state.tg.sendMessage(chat_id, "Failed to get stats.") catch {};
            return;
        };
        defer state.allocator.free(result);
        state.tg.sendMessage(chat_id, result) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "clear")) {
        state.cortex.clear();
        state.tg.sendMessage(chat_id, "All memories cleared.") catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "delete")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory delete <id>") catch {};
            return;
        }
        const id = std.fmt.parseInt(u64, sub_args, 10) catch {
            state.tg.sendMessage(chat_id, "Invalid ID. Use a numeric memory ID.") catch {};
            return;
        };
        if (state.cortex.delete(id)) {
            state.tg.sendMessage(chat_id, "Memory deleted.") catch {};
        } else {
            state.tg.sendMessage(chat_id, "Memory not found.") catch {};
        }
        return;
    }

    state.tg.sendMessage(chat_id, "Unknown subcommand. Use /memory for help.") catch {};
}

// ── Entry Point ───────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) std.log.err("Memory leak detected!", .{});
    }
    const allocator = gpa.allocator();

    std.log.info("Starting AI Agent Bot...", .{});

    // Determine working directory: CLI arg or current directory
    const cli_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, cli_args);

    const work_dir: []const u8 = if (cli_args.len > 1) cli_args[1] else ".";
    std.log.info("Working directory: {s}", .{work_dir});

    // Build paths relative to working directory
    const auth_path = try std.fs.path.join(allocator, &.{ work_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_path = try std.fs.path.join(allocator, &.{ work_dir, "models.json" });
    defer allocator.free(models_path);
    const users_path = try std.fs.path.join(allocator, &.{ work_dir, "allowed_users.json" });
    defer allocator.free(users_path);
    const agents_dir = try std.fs.path.join(allocator, &.{ work_dir, "agents" });
    defer allocator.free(agents_dir);
    const teams_dir = try std.fs.path.join(allocator, &.{ work_dir, "teams" });
    defer allocator.free(teams_dir);
    const skills_dir = try std.fs.path.join(allocator, &.{ work_dir, "skills" });
    defer allocator.free(skills_dir);
    const persist_dir = try std.fs.path.join(allocator, &.{ work_dir, "memory" });
    defer allocator.free(persist_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ work_dir, "workspaces" });
    defer allocator.free(workspace_dir);

    // Ensure directories exist
    for ([_][]const u8{ agents_dir, teams_dir, skills_dir, persist_dir, workspace_dir }) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Load configs (use path-aware loading)
    const auth_content = std.fs.cwd().readFileAlloc(allocator, auth_path, 1024 * 1024) catch |err| {
        std.log.err("Failed to read {s}: {s}", .{ auth_path, @errorName(err) });
        return err;
    };
    defer allocator.free(auth_content);

    const auth_parsed = std.json.parseFromSlice(config.AuthConfig, allocator, auth_content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse auth.json: {s}", .{@errorName(err)});
        return err;
    };
    defer auth_parsed.deinit();

    const models_content = std.fs.cwd().readFileAlloc(allocator, models_path, 1024 * 1024) catch |err| {
        std.log.err("Failed to read {s}: {s}", .{ models_path, @errorName(err) });
        return err;
    };
    defer allocator.free(models_content);

    const models_parsed = std.json.parseFromSlice(config.ModelConfig, allocator, models_content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse models.json: {s}", .{@errorName(err)});
        return err;
    };
    defer models_parsed.deinit();

    // Load allowed users
    const allowed_users = config.loadAllowedUsers(allocator) catch blk: {
        std.log.warn("Failed to load allowed_users, allowing all.", .{});
        break :blk allocator.alloc(i64, 0) catch return error.OutOfMemory;
    };
    defer allocator.free(allowed_users);

    // Initialize Telegram
    var tg_client = try telegram.TelegramClient.init(allocator, auth_parsed.value.telegram_bot_token, allowed_users);
    defer tg_client.deinit();

    tg_client.setMyCommands() catch |err| {
        std.log.warn("Failed to set commands: {s}", .{@errorName(err)});
    };

    // Initialize LLM client
    var llm_client = llm.LlmClient.init(allocator, auth_parsed.value.llm_api_key, models_parsed.value.llm_endpoint_url);
    defer llm_client.deinit();

    // Initialize tool registry
    var tool_registry = tools_mod.ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.register(tools_mod.BashTool.definition());

    // Load MCP servers (adds tools to registry dynamically)
    const mcp_config_path = try std.fs.path.join(allocator, &.{ work_dir, "mcp_servers.json" });
    defer allocator.free(mcp_config_path);
    var mcp_manager = try mcp.loadMcpServers(allocator, mcp_config_path);
    defer mcp_manager.deinit();

    mcp_manager.registerToolsInRegistry(&tool_registry) catch |err| {
        std.log.warn("Failed to register MCP tools: {s}", .{@errorName(err)});
    };

    if (mcp_manager.toolCount() > 0) {
        std.log.info("MCP: {d} tools loaded from {d} servers", .{ mcp_manager.toolCount(), mcp_manager.clients.count() });
    }

    // Load agents
    var agents = try agent_mod.loadAllAgents(allocator, agents_dir);
    defer {
        var it = agents.iterator();
        while (it.next()) |entry| agent_mod.freeAgent(allocator, entry.value_ptr.*);
        agents.deinit();
    }

    if (agents.count() == 0) {
        std.log.warn("No agents found in {s}", .{agents_dir});
    }

    // Load teams
    var teams = try team_mod.loadAllTeams(allocator, teams_dir);
    defer {
        var it = teams.iterator();
        while (it.next()) |entry| team_mod.freeTeam(allocator, entry.value_ptr.*);
        teams.deinit();
    }

    // Validate teams
    {
        var it = teams.iterator();
        while (it.next()) |entry| {
            if (!team_mod.validateTeam(entry.value_ptr.*, &agents)) {
                std.log.warn("Team '{s}' has missing agents", .{entry.key_ptr.*});
            }
        }
    }

    // Memory cortex
    var cortex = try memory_cortex.MemoryCortex.init(allocator, persist_dir);
    defer cortex.deinit();

    // Agent runtime
    var runtime = agent_mod.AgentRuntime.init(allocator, &llm_client, &tool_registry, &tg_client, skills_dir);
    runtime.mcp_manager = &mcp_manager;

    // Orchestrator
    var orch = orchestrator_mod.Orchestrator.init(
        allocator,
        &agents,
        &teams,
        &runtime,
        &tg_client,
        &llm_client,
        workspace_dir,
    );
    defer orch.deinit();

    // App state
    var state = AppState{
        .allocator = allocator,
        .tg = &tg_client,
        .llm_client = &llm_client,
        .agents = agents,
        .teams = teams,
        .tool_registry = &tool_registry,
        .runtime = &runtime,
        .orchestrator = &orch,
        .chat_states = std.AutoHashMap(i64, ChatState).init(allocator),
        .conversations = std.AutoHashMap(i64, conversation.Conversation).init(allocator),
        .cortex = &cortex,
        .work_dir = work_dir,
        .persist_dir = persist_dir,
        .max_history = 50,
        .max_context = 20,
        .last_reload_check = std.time.timestamp(),
    };
    defer {
        var conv_it = state.conversations.iterator();
        while (conv_it.next()) |entry| entry.value_ptr.deinit(allocator);
        state.conversations.deinit();
        var cs_it = state.chat_states.iterator();
        while (cs_it.next()) |entry| entry.value_ptr.deinit(allocator);
        state.chat_states.deinit();
    }

    // Set default active agent (will be per-chat on first message)
    std.log.info("Bot ready with {d} agents, {d} teams.", .{ agents.count(), teams.count() });

    // Main polling loop
    while (true) {
        // Hot reload check every 5 seconds
        const now = std.time.timestamp();
        if (now - state.last_reload_check >= 5) {
            agent_mod.reloadAgents(allocator, &state.agents);
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
            std.log.info("Message from {d}: {s}", .{ msg.user_id, msg.text });

            // Auto-assign default agent if chat has no state
            if (!state.chat_states.contains(msg.chat_id)) {
                // Pick "assistant" agent or first available
                if (agents.get("assistant")) |_| {
                    state.setActiveAgent(msg.chat_id, "assistant") catch {};
                } else {
                    var it = agents.iterator();
                    if (it.next()) |entry| {
                        state.setActiveAgent(msg.chat_id, entry.key_ptr.*) catch {};
                    }
                }
            }

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
