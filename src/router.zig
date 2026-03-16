//! Super Agent: autonomous router that decides how to handle each user message.
//! Uses LLM with meta-tools (respond_directly, delegate_to_agent, start_team_task)
//! to route messages to the right handler without user intervention.
const std = @import("std");
const llm = @import("llm.zig");
const agent_mod = @import("agent.zig");
const team_mod = @import("team.zig");
const conversation = @import("conversation.zig");
const telegram = @import("telegram.zig");
const orchestrator_mod = @import("orchestrator.zig");

// ── Routing Decision ──────────────────────────────────────────────

pub const RoutingDecision = union(enum) {
    respond_directly: []const u8,
    delegate_to_agent: struct {
        agent_id: []const u8,
        task: []const u8,
    },
    start_team_task: struct {
        team_id: []const u8,
        task: []const u8,
    },
};

// ── Super Agent ───────────────────────────────────────────────────

pub const SuperAgent = struct {
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,
    agents: *std.StringHashMap(*agent_mod.AgentDef),
    teams: *std.StringHashMap(*team_mod.TeamDef),
    runtime: *agent_mod.AgentRuntime,
    orchestrator: *orchestrator_mod.Orchestrator,
    tg: *telegram.TelegramClient,
    model_id: []const u8,
    api_format: llm.ApiFormat,
    routing_convs: std.AutoHashMap(i64, conversation.Conversation),
    agent_convs: *std.AutoHashMap(i64, conversation.Conversation),
    persist_dir: []const u8,
    max_routing_history: usize,
    max_agent_history: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        llm_client: *llm.LlmClient,
        agents: *std.StringHashMap(*agent_mod.AgentDef),
        teams: *std.StringHashMap(*team_mod.TeamDef),
        runtime: *agent_mod.AgentRuntime,
        orchestrator: *orchestrator_mod.Orchestrator,
        tg: *telegram.TelegramClient,
        model_id: []const u8,
        persist_dir: []const u8,
        agent_convs: *std.AutoHashMap(i64, conversation.Conversation),
    ) SuperAgent {
        return .{
            .allocator = allocator,
            .llm_client = llm_client,
            .agents = agents,
            .teams = teams,
            .runtime = runtime,
            .orchestrator = orchestrator,
            .tg = tg,
            .model_id = model_id,
            .api_format = agent_mod.apiFormatForModel(model_id),
            .routing_convs = std.AutoHashMap(i64, conversation.Conversation).init(allocator),
            .agent_convs = agent_convs,
            .persist_dir = persist_dir,
            .max_routing_history = 20,
            .max_agent_history = 50,
        };
    }

    pub fn deinit(self: *SuperAgent) void {
        var it = self.routing_convs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.routing_convs.deinit();
    }

    // ── Main Entry Point ──────────────────────────────────────────

    /// Handle a user message. Routes autonomously.
    /// Returns the chat mode to set (for orchestrator handoff).
    pub fn handleMessage(self: *SuperAgent, chat_id: i64, text: []const u8) HandleResult {
        self.tg.sendTyping(chat_id) catch {};

        // Route via LLM
        const decision = self.route(chat_id, text) catch |err| {
            std.log.err("Routing error: {s}", .{@errorName(err)});
            self.tg.sendMessage(chat_id, "Sorry, something went wrong. Please try again.") catch {};
            return .stay;
        };

        // Execute
        return self.executeDecision(chat_id, decision, text);
    }

    pub const HandleResult = enum {
        stay, // remain in super_agent mode
        team_task, // switched to team_task mode
    };

    // ── Routing Logic ─────────────────────────────────────────────

    fn route(self: *SuperAgent, chat_id: i64, text: []const u8) !RoutingDecision {
        // Get or create routing conversation
        const conv = try self.getOrCreateRoutingConv(chat_id);
        conv.addMessage(self.allocator, "user", text) catch {};
        conv.trim(self.allocator, self.max_routing_history);

        // Build system prompt with agent/team listings
        const system_prompt = try self.buildRoutingSystemPrompt();
        defer self.allocator.free(system_prompt);

        // Build tools JSON
        const tools_json = try self.buildRoutingToolsJson();
        defer self.allocator.free(tools_json);

        // Build messages array
        var messages: std.ArrayList(llm.RichMessage) = .empty;
        defer messages.deinit(self.allocator);

        try messages.append(self.allocator, .{ .role = "system", .content = system_prompt });
        for (conv.messages.items) |msg| {
            try messages.append(self.allocator, .{
                .role = msg.role,
                .content = msg.content,
                .tool_call_id = msg.tool_call_id,
                .tool_calls_json = msg.tool_calls_json,
            });
        }

        // Call LLM with routing tools
        const response = try self.llm_client.chatCompletionWithTools(
            messages.items,
            self.model_id,
            0.3, // low temperature for deterministic routing
            self.api_format,
            tools_json,
        );
        defer response.deinit(self.allocator);

        // Parse response
        if (response.hasToolCalls()) {
            const call = response.tool_calls.?[0]; // take first tool call
            const decision = try self.parseRoutingToolCall(call);

            // Add assistant routing decision to routing conv as summary
            const summary = self.formatDecisionSummary(decision) catch null;
            if (summary) |s| {
                conv.addMessage(self.allocator, "assistant", s) catch {};
                self.allocator.free(s);
            }

            return decision;
        }

        // Fallback: LLM returned text without tool call -> treat as respond_directly
        if (response.content) |content| {
            const duped = try self.allocator.dupe(u8, content);
            conv.addMessage(self.allocator, "assistant", content) catch {};
            return .{ .respond_directly = duped };
        }

        return .{ .respond_directly = try self.allocator.dupe(u8, "I'm not sure how to help with that. Could you rephrase?") };
    }

    // ── Decision Execution ────────────────────────────────────────

    fn executeDecision(self: *SuperAgent, chat_id: i64, decision: RoutingDecision, original_text: []const u8) HandleResult {
        switch (decision) {
            .respond_directly => |message| {
                self.tg.sendMessage(chat_id, message) catch {};
                self.allocator.free(message);
                return .stay;
            },
            .delegate_to_agent => |info| {
                defer self.allocator.free(info.agent_id);
                defer self.allocator.free(info.task);
                self.delegateToAgent(chat_id, info.agent_id, original_text);
                return .stay;
            },
            .start_team_task => |info| {
                defer self.allocator.free(info.task);
                const result = self.startTeamTask(chat_id, info.team_id, info.task);
                self.allocator.free(info.team_id);
                return result;
            },
        }
    }

    fn delegateToAgent(self: *SuperAgent, chat_id: i64, agent_id: []const u8, user_text: []const u8) void {
        const agent_def = self.agents.get(agent_id) orelse {
            const msg = std.fmt.allocPrint(self.allocator, "Agent '{s}' not found. Let me answer directly.", .{agent_id}) catch return;
            defer self.allocator.free(msg);
            self.tg.sendMessage(chat_id, msg) catch {};
            return;
        };

        std.log.info("[router] Delegating to {s}: {s}", .{ agent_id, user_text });

        // Get or create agent conversation (separate from routing conv)
        const conv = self.getOrCreateAgentConv(chat_id) catch {
            self.tg.sendMessage(chat_id, "Memory error.") catch {};
            return;
        };

        conv.addMessage(self.allocator, "user", user_text) catch return;
        conv.trim(self.allocator, self.max_agent_history);

        if (agent_def.tool_names.len > 0) {
            // Agentic mode with tool-use loop
            const progress_id = self.tg.sendMessageReturningId(chat_id, "Thinking...") catch 0;
            const progress = if (progress_id != 0) progress_id else null;

            const response = self.runtime.run(
                agent_def,
                conv,
                chat_id,
                progress,
                null,
            ) catch |err| {
                std.log.err("Agent runtime error: {s}", .{@errorName(err)});
                self.tg.sendMessage(chat_id, "Sorry, the agent encountered an error.") catch {};
                self.addRoutingSummary(chat_id, agent_id, "failed");
                return;
            };
            defer self.allocator.free(response);

            conv.addMessage(self.allocator, "assistant", response) catch {};
            conversation.saveConversation(self.allocator, self.persist_dir, chat_id, conv);

            // Send response (edit progress or send new)
            if (progress) |pid| {
                if (response.len <= 4096) {
                    self.tg.editMessage(chat_id, pid, response) catch {
                        self.tg.sendMessage(chat_id, response) catch {};
                    };
                } else {
                    self.tg.editMessage(chat_id, pid, "Done! See response below:") catch {};
                    self.tg.sendMessage(chat_id, response) catch {};
                }
            } else {
                self.tg.sendMessage(chat_id, response) catch {};
            }

            self.addRoutingSummary(chat_id, agent_id, "completed");
        } else {
            // Simple LLM mode (no tools)
            const system_prompt = agent_mod.buildSystemPrompt(self.allocator, agent_def, self.runtime.skills_dir) catch {
                self.tg.sendMessage(chat_id, "Error building prompt.") catch {};
                return;
            };
            defer self.allocator.free(system_prompt);

            const items = conv.messages.items;
            const start = if (items.len > 20) items.len - 20 else 0;
            const context_msgs = items[start..];

            const final_messages = self.allocator.alloc(llm.ChatMessage, 1 + context_msgs.len) catch return;
            defer self.allocator.free(final_messages);

            final_messages[0] = .{ .role = "system", .content = system_prompt };
            for (context_msgs, 1..) |msg, i| {
                final_messages[i] = .{ .role = msg.role, .content = msg.content orelse "" };
            }

            const response = self.llm_client.chatCompletion(
                final_messages,
                agent_def.model_id,
                agent_def.temperature,
                agent_def.api_format,
            ) catch |err| {
                std.log.err("LLM error: {s}", .{@errorName(err)});
                self.tg.sendMessage(chat_id, "Sorry, the AI service returned an error.") catch {};
                return;
            };
            defer self.allocator.free(response);

            conv.addMessage(self.allocator, "assistant", response) catch {};
            conversation.saveConversation(self.allocator, self.persist_dir, chat_id, conv);
            self.tg.sendMessage(chat_id, response) catch {};
            self.addRoutingSummary(chat_id, agent_id, "completed");
        }
    }

    fn startTeamTask(self: *SuperAgent, chat_id: i64, team_id: []const u8, task: []const u8) HandleResult {
        const team_def = self.teams.get(team_id) orelse {
            const msg = std.fmt.allocPrint(self.allocator, "Team '{s}' not found.", .{team_id}) catch return .stay;
            defer self.allocator.free(msg);
            self.tg.sendMessage(chat_id, msg) catch {};
            return .stay;
        };

        std.log.info("[router] Starting team task with {s}: {s}", .{ team_id, task });

        self.orchestrator.startTask(chat_id, team_def, task) catch |err| {
            std.log.err("Failed to start task: {s}", .{@errorName(err)});
            self.tg.sendMessage(chat_id, "Failed to start team task.") catch {};
            return .stay;
        };

        self.addRoutingSummary(chat_id, team_id, "team task started");
        return .team_task;
    }

    // ── System Prompt Builder ─────────────────────────────────────

    fn buildRoutingSystemPrompt(self: *SuperAgent) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print(
            \\You are an autonomous AI assistant. Analyze each user message and decide the best way to handle it.
            \\
            \\You MUST call exactly ONE tool for every message:
            \\- respond_directly: For greetings, simple questions, general knowledge, clarifications, or anything you can answer without tools.
            \\- delegate_to_agent: For tasks that need specialized tools or expertise (coding, file operations, web search, code review, etc.)
            \\- start_team_task: ONLY for complex multi-step projects that genuinely need planning, multiple specialists, and review.
            \\
            \\Guidelines:
            \\- Simple conversations -> respond_directly
            \\- Single focused tasks (write code, search web, run command) -> delegate_to_agent
            \\- Large projects (build an app, multi-file changes with review) -> start_team_task
            \\- When delegating, choose the most appropriate agent based on the task.
            \\- Pass the user's full request as the task context.
            \\
        , .{});

        // List available agents
        try w.print("\\nAvailable Agents:\\n", .{});
        var agent_it = self.agents.iterator();
        while (agent_it.next()) |entry| {
            const ag = entry.value_ptr.*;
            try w.print("- {s}: {s} - {s}", .{ ag.id, ag.name, ag.description });
            if (ag.tool_names.len > 0) {
                try w.print(" (tools:", .{});
                for (ag.tool_names, 0..) |t, i| {
                    if (i > 0) try w.print(",", .{});
                    try w.print(" {s}", .{t});
                }
                try w.print(")", .{});
            }
            if (ag.skill_names.len > 0) {
                try w.print(" (skills:", .{});
                for (ag.skill_names, 0..) |s, i| {
                    if (i > 0) try w.print(",", .{});
                    try w.print(" {s}", .{s});
                }
                try w.print(")", .{});
            }
            try w.print("\\n", .{});
        }

        // List available teams
        if (self.teams.count() > 0) {
            try w.print("\\nAvailable Teams:\\n", .{});
            var team_it = self.teams.iterator();
            while (team_it.next()) |entry| {
                const tm = entry.value_ptr.*;
                try w.print("- {s}: {s} - {s} ({d} roles)\\n", .{ tm.id, tm.name, tm.description, tm.roles.len });
            }
        }

        return try self.allocator.dupe(u8, buf.items);
    }

    // ── Routing Tools JSON ────────────────────────────────────────

    fn buildRoutingToolsJson(self: *SuperAgent) ![]u8 {
        const tools_json =
            \\[{"type":"function","function":{"name":"respond_directly","description":"Respond directly to the user for simple questions, greetings, or general knowledge.","parameters":{"type":"object","properties":{"message":{"type":"string","description":"The complete response message to send"}},"required":["message"]}}},{"type":"function","function":{"name":"delegate_to_agent","description":"Delegate to a specialized agent for tasks needing tools or expertise.","parameters":{"type":"object","properties":{"agent_id":{"type":"string","description":"The agent ID to delegate to"},"task":{"type":"string","description":"Description of what the agent should do"}},"required":["agent_id","task"]}}},{"type":"function","function":{"name":"start_team_task","description":"Start a multi-agent team task for complex projects needing planning and review.","parameters":{"type":"object","properties":{"team_id":{"type":"string","description":"The team ID to activate"},"task":{"type":"string","description":"Full project description"}},"required":["team_id","task"]}}}]
        ;
        return try self.allocator.dupe(u8, tools_json);
    }

    // ── Tool Call Parsing ─────────────────────────────────────────

    fn parseRoutingToolCall(self: *SuperAgent, call: llm.ToolCall) !RoutingDecision {
        if (std.mem.eql(u8, call.function_name, "respond_directly")) {
            const Args = struct { message: []const u8 };
            const parsed = std.json.parseFromSlice(Args, self.allocator, call.arguments_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                return .{ .respond_directly = try self.allocator.dupe(u8, call.arguments_json) };
            };
            defer parsed.deinit();
            return .{ .respond_directly = try self.allocator.dupe(u8, parsed.value.message) };
        }

        if (std.mem.eql(u8, call.function_name, "delegate_to_agent")) {
            const Args = struct { agent_id: []const u8, task: []const u8 };
            const parsed = std.json.parseFromSlice(Args, self.allocator, call.arguments_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.JsonParseError;
            };
            defer parsed.deinit();
            return .{ .delegate_to_agent = .{
                .agent_id = try self.allocator.dupe(u8, parsed.value.agent_id),
                .task = try self.allocator.dupe(u8, parsed.value.task),
            } };
        }

        if (std.mem.eql(u8, call.function_name, "start_team_task")) {
            const Args = struct { team_id: []const u8, task: []const u8 };
            const parsed = std.json.parseFromSlice(Args, self.allocator, call.arguments_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.JsonParseError;
            };
            defer parsed.deinit();
            return .{ .start_team_task = .{
                .team_id = try self.allocator.dupe(u8, parsed.value.team_id),
                .task = try self.allocator.dupe(u8, parsed.value.task),
            } };
        }

        // Unknown tool - treat as direct response
        return .{ .respond_directly = try self.allocator.dupe(u8, "I'm not sure how to help with that.") };
    }

    // ── Conversation Helpers ──────────────────────────────────────

    fn getOrCreateRoutingConv(self: *SuperAgent, chat_id: i64) !*conversation.Conversation {
        const result = try self.routing_convs.getOrPut(chat_id);
        if (!result.found_existing) {
            result.value_ptr.* = conversation.Conversation.init();
        }
        return result.value_ptr;
    }

    fn getOrCreateAgentConv(self: *SuperAgent, chat_id: i64) !*conversation.Conversation {
        const result = try self.agent_convs.getOrPut(chat_id);
        if (!result.found_existing) {
            if (conversation.loadConversation(self.allocator, self.persist_dir, chat_id)) |loaded| {
                result.value_ptr.* = loaded;
            } else {
                result.value_ptr.* = conversation.Conversation.init();
            }
        }
        return result.value_ptr;
    }

    fn addRoutingSummary(self: *SuperAgent, chat_id: i64, target: []const u8, status: []const u8) void {
        const conv = self.getOrCreateRoutingConv(chat_id) catch return;
        const summary = std.fmt.allocPrint(self.allocator, "[Delegated to {s}: {s}]", .{ target, status }) catch return;
        defer self.allocator.free(summary);
        conv.addMessage(self.allocator, "assistant", summary) catch {};
    }

    fn formatDecisionSummary(self: *SuperAgent, decision: RoutingDecision) ![]u8 {
        return switch (decision) {
            .respond_directly => try self.allocator.dupe(u8, "[Responding directly]"),
            .delegate_to_agent => |info| try std.fmt.allocPrint(self.allocator, "[Routing to agent: {s}]", .{info.agent_id}),
            .start_team_task => |info| try std.fmt.allocPrint(self.allocator, "[Starting team task: {s}]", .{info.team_id}),
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "parse respond_directly args" {
    const allocator = std.testing.allocator;
    const json = "{\"message\":\"Hello there!\"}";
    const Args = struct { message: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Hello there!", parsed.value.message);
}

test "parse delegate_to_agent args" {
    const allocator = std.testing.allocator;
    const json = "{\"agent_id\":\"software_engineer\",\"task\":\"write hello world\"}";
    const Args = struct { agent_id: []const u8, task: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("software_engineer", parsed.value.agent_id);
    try std.testing.expectEqualStrings("write hello world", parsed.value.task);
}

test "parse start_team_task args" {
    const allocator = std.testing.allocator;
    const json = "{\"team_id\":\"web_dev\",\"task\":\"build a landing page\"}";
    const Args = struct { team_id: []const u8, task: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("web_dev", parsed.value.team_id);
    try std.testing.expectEqualStrings("build a landing page", parsed.value.task);
}
