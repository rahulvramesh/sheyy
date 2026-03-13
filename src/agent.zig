//! Agent system: enhanced agent definitions with tools/skills and the agentic tool-use loop
const std = @import("std");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const conversation = @import("conversation.zig");
const telegram = @import("telegram.zig");
const mcp = @import("mcp.zig");

// ── Agent Definition ──────────────────────────────────────────────

pub const AgentDef = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    model_id: []const u8,
    temperature: f32,
    api_format: llm.ApiFormat,
    source_path: ?[]const u8,
    last_modified: ?i128,

    // Tool & skill support
    tool_names: []const []const u8, // e.g., ["bash"]
    skill_names: []const []const u8, // e.g., ["github.md", "daytona.md"]
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
    tools: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
};

/// Determine API format from model ID
pub fn apiFormatForModel(model_id: []const u8) llm.ApiFormat {
    if (std.mem.startsWith(u8, model_id, "claude")) return .anthropic;
    if (std.mem.startsWith(u8, model_id, "minimax")) return .anthropic;
    return .openai;
}

pub fn getFileMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

/// Load a single agent from a JSON file
pub fn loadAgent(allocator: std.mem.Allocator, file_path: []const u8) !*AgentDef {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(AgentJson, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const def = try allocator.create(AgentDef);
    errdefer allocator.destroy(def);

    const v = parsed.value;

    // Dupe tool names
    const tool_names = if (v.tools) |t| blk: {
        const names = try allocator.alloc([]const u8, t.len);
        for (t, 0..) |name, i| {
            names[i] = try allocator.dupe(u8, name);
        }
        break :blk names;
    } else try allocator.alloc([]const u8, 0);

    // Dupe skill names
    const skill_names = if (v.skills) |s| blk: {
        const names = try allocator.alloc([]const u8, s.len);
        for (s, 0..) |name, i| {
            names[i] = try allocator.dupe(u8, name);
        }
        break :blk names;
    } else try allocator.alloc([]const u8, 0);

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
        .tool_names = tool_names,
        .skill_names = skill_names,
    };
    return def;
}

pub fn freeAgent(allocator: std.mem.Allocator, def: *AgentDef) void {
    allocator.free(def.id);
    allocator.free(def.name);
    allocator.free(def.description);
    allocator.free(def.system_prompt);
    allocator.free(def.model_id);
    if (def.source_path) |p| allocator.free(p);
    for (def.tool_names) |name| allocator.free(name);
    allocator.free(def.tool_names);
    for (def.skill_names) |name| allocator.free(name);
    allocator.free(def.skill_names);
    allocator.destroy(def);
}

/// Load all agents from a directory
pub fn loadAllAgents(allocator: std.mem.Allocator, dir_path: []const u8) !std.StringHashMap(*AgentDef) {
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

        std.log.info("Loaded agent: {s} ({s}) tools={d} skills={d}", .{
            agent_def.name, agent_def.id, agent_def.tool_names.len, agent_def.skill_names.len,
        });
    }

    return agents;
}

/// Hot-reload agents that have changed on disk
pub fn reloadAgents(allocator: std.mem.Allocator, agents: *std.StringHashMap(*AgentDef)) void {
    var it = agents.iterator();
    while (it.next()) |entry| {
        const ag = entry.value_ptr.*;
        const path = ag.source_path orelse continue;

        const current_mtime = getFileMtime(path) catch continue;
        const last_mtime = ag.last_modified orelse current_mtime;

        if (current_mtime > last_mtime) {
            std.log.info("Reloading agent: {s}", .{ag.id});

            const new_agent = loadAgent(allocator, path) catch |err| {
                std.log.err("Reload failed for {s}: {s}", .{ ag.id, @errorName(err) });
                continue;
            };

            freeAgent(allocator, ag);
            entry.value_ptr.* = new_agent;
        }
    }
}

// ── Skill Loading ─────────────────────────────────────────────────

/// Load a skill markdown file and return its content
pub fn loadSkillContent(allocator: std.mem.Allocator, skill_path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, skill_path, 1024 * 1024);
}

/// Build the full system prompt: base prompt + injected skill contents
pub fn buildSystemPrompt(allocator: std.mem.Allocator, agent_def: *const AgentDef, skills_dir: []const u8) ![]u8 {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(allocator);
    const w = parts.writer(allocator);

    // Base system prompt
    try w.print("{s}", .{agent_def.system_prompt});

    // Append each skill file
    for (agent_def.skill_names) |skill_name| {
        const skill_path = try std.fs.path.join(allocator, &.{ skills_dir, skill_name });
        defer allocator.free(skill_path);

        const skill_content = loadSkillContent(allocator, skill_path) catch |err| {
            std.log.warn("Failed to load skill {s}: {s}", .{ skill_name, @errorName(err) });
            continue;
        };
        defer allocator.free(skill_content);

        try w.print("\n\n---\n{s}", .{skill_content});
    }

    // If agent has tools, add tool usage instructions
    if (agent_def.tool_names.len > 0) {
        try w.print("\n\nYou have access to tools. Use them when needed to accomplish tasks. When you need to execute commands, use the bash tool.", .{});
    }

    return try allocator.dupe(u8, parts.items);
}

// ── Agent Runtime (Tool-Use Loop) ─────────────────────────────────

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,
    tool_registry: *tools_mod.ToolRegistry,
    tg: *telegram.TelegramClient,
    max_tool_iterations: usize,
    skills_dir: []const u8,
    mcp_manager: ?*mcp.McpManager,

    pub fn init(
        allocator: std.mem.Allocator,
        llm_client: *llm.LlmClient,
        tool_registry: *tools_mod.ToolRegistry,
        tg: *telegram.TelegramClient,
        skills_dir: []const u8,
    ) AgentRuntime {
        return .{
            .allocator = allocator,
            .llm_client = llm_client,
            .tool_registry = tool_registry,
            .tg = tg,
            .max_tool_iterations = 15,
            .skills_dir = skills_dir,
            .mcp_manager = null,
        };
    }

    /// Run one full agentic turn: LLM call -> tool execution -> repeat until text response.
    /// Returns owned text response string.
    pub fn run(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        conv: *conversation.Conversation,
        chat_id: i64,
        progress_msg_id: ?i64,
        working_dir: ?[]const u8,
    ) ![]u8 {
        // Build full system prompt with skills
        const system_prompt = try buildSystemPrompt(self.allocator, agent_def, self.skills_dir);
        defer self.allocator.free(system_prompt);

        // Build tools JSON if agent has tools
        const has_tools = agent_def.tool_names.len > 0;
        const tools_json: ?[]u8 = if (has_tools) blk: {
            break :blk switch (agent_def.api_format) {
                .openai => try self.tool_registry.toOpenAIToolsJson(self.allocator),
                .anthropic => try self.tool_registry.toAnthropicToolsJson(self.allocator),
            };
        } else null;
        defer if (tools_json) |j| self.allocator.free(j);

        // Working messages for this turn (rebuilt each iteration from conv + tool exchanges)
        var tool_messages: std.ArrayList(llm.RichMessage) = .empty;
        defer tool_messages.deinit(self.allocator);

        var iterations: usize = 0;
        while (iterations < self.max_tool_iterations) : (iterations += 1) {
            // Build messages array: system + conversation history + tool exchange messages
            var messages: std.ArrayList(llm.RichMessage) = .empty;
            defer messages.deinit(self.allocator);

            // System prompt
            try messages.append(self.allocator, .{ .role = "system", .content = system_prompt });

            // Conversation history
            for (conv.messages.items) |msg| {
                try messages.append(self.allocator, .{
                    .role = msg.role,
                    .content = msg.content,
                    .tool_call_id = msg.tool_call_id,
                    .tool_calls_json = msg.tool_calls_json,
                });
            }

            // Tool exchange messages from this turn
            for (tool_messages.items) |msg| {
                try messages.append(self.allocator, msg);
            }

            // Call LLM
            const response = try self.llm_client.chatCompletionWithTools(
                messages.items,
                agent_def.model_id,
                agent_def.temperature,
                agent_def.api_format,
                tools_json,
            );
            defer {
                // We'll dupe what we need before this defer runs
            }

            if (response.hasToolCalls()) {
                const calls = response.tool_calls.?;

                // Store assistant message with tool_calls
                if (response.raw_tool_calls_json) |raw_json| {
                    const raw_copy = try self.allocator.dupe(u8, raw_json);
                    try tool_messages.append(self.allocator, .{
                        .role = "assistant",
                        .content = null,
                        .tool_calls_json = raw_copy,
                    });
                }

                // Execute each tool call
                for (calls) |call| {
                    // Update progress
                    if (progress_msg_id) |pid| {
                        const progress_text = try std.fmt.allocPrint(self.allocator, "Running: {s}...", .{call.function_name});
                        defer self.allocator.free(progress_text);
                        self.tg.editMessage(chat_id, pid, progress_text) catch {};
                    }

                    // Route tool call: MCP tools vs built-in bash
                    const tool_output = self.executeTool(call, agent_def, working_dir) catch |err| {
                        const err_text = try std.fmt.allocPrint(self.allocator, "Error: {s}", .{@errorName(err)});
                        const call_id_copy = try self.allocator.dupe(u8, call.id);
                        try tool_messages.append(self.allocator, .{
                            .role = "tool",
                            .content = err_text,
                            .tool_call_id = call_id_copy,
                        });
                        continue;
                    };

                    const call_id_copy = try self.allocator.dupe(u8, call.id);
                    try tool_messages.append(self.allocator, .{
                        .role = "tool",
                        .content = tool_output,
                        .tool_call_id = call_id_copy,
                    });
                }

                // Free the response (we've copied what we need)
                response.deinit(self.allocator);

                // Continue the loop for next LLM call
                continue;
            }

            // No tool calls -- we have a final text response
            if (response.content) |content| {
                const result = try self.allocator.dupe(u8, content);
                response.deinit(self.allocator);
                // Clean up tool messages
                for (tool_messages.items) |msg| {
                    if (msg.content) |c| self.allocator.free(c);
                    if (msg.tool_call_id) |id| self.allocator.free(id);
                    if (msg.tool_calls_json) |j| self.allocator.free(j);
                }
                return result;
            }

            response.deinit(self.allocator);
            break;
        }

        // Clean up tool messages on exit
        for (tool_messages.items) |msg| {
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls_json) |j| self.allocator.free(j);
        }

        return try self.allocator.dupe(u8, "I was unable to complete the task within the allowed number of steps.");
    }

    /// Route a tool call to the right executor: MCP server or built-in bash
    fn executeTool(self: *AgentRuntime, call: llm.ToolCall, agent_def: *const AgentDef, working_dir: ?[]const u8) ![]u8 {
        // Check if this is an MCP tool
        if (self.mcp_manager) |mgr| {
            if (mgr.isToolMcp(call.function_name)) {
                std.log.info("[{s}] mcp:{s} args={s}", .{ agent_def.id, call.function_name, call.arguments_json });
                const result = mgr.callTool(call.function_name, call.arguments_json) catch |err| {
                    return try std.fmt.allocPrint(self.allocator, "MCP tool error: {s}", .{@errorName(err)});
                };
                defer self.allocator.free(result);
                return self.truncateOutput(result);
            }
        }

        // Built-in bash tool
        if (std.mem.eql(u8, call.function_name, "bash")) {
            const command = self.parseCommandFromArgs(call.arguments_json) catch {
                return try self.allocator.dupe(u8, "Error: could not parse tool arguments");
            };
            defer self.allocator.free(command);

            std.log.info("[{s}] bash: {s}", .{ agent_def.id, command });

            const result = tools_mod.BashTool.execute(self.allocator, command, working_dir) catch |err| {
                return try std.fmt.allocPrint(self.allocator, "Error executing command: {s}", .{@errorName(err)});
            };
            defer result.deinit(self.allocator);

            const output = try self.truncateOutput(result.output);

            if (!result.success) {
                const with_code = try std.fmt.allocPrint(
                    self.allocator,
                    "Exit code {d}:\n{s}",
                    .{ result.exit_code, output },
                );
                self.allocator.free(output);
                return with_code;
            }
            return output;
        }

        return try std.fmt.allocPrint(self.allocator, "Unknown tool: {s}", .{call.function_name});
    }

    fn truncateOutput(self: *AgentRuntime, output: []const u8) ![]u8 {
        const max_output = 50 * 1024; // 50KB for LLM context
        if (output.len > max_output) {
            const truncated = try std.fmt.allocPrint(
                self.allocator,
                "{s}\n... (output truncated, {d} bytes total)",
                .{ output[0..max_output], output.len },
            );
            return truncated;
        }
        return try self.allocator.dupe(u8, output);
    }

    fn parseCommandFromArgs(self: *AgentRuntime, args_json: []const u8) ![]u8 {
        const Args = struct { command: []const u8 };
        const parsed = std.json.parseFromSlice(Args, self.allocator, args_json, .{
            .ignore_unknown_fields = true,
        }) catch return error.JsonParseError;
        defer parsed.deinit();
        return try self.allocator.dupe(u8, parsed.value.command);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "apiFormatForModel" {
    try std.testing.expectEqual(llm.ApiFormat.anthropic, apiFormatForModel("claude-sonnet-4"));
    try std.testing.expectEqual(llm.ApiFormat.openai, apiFormatForModel("gpt-4o"));
    try std.testing.expectEqual(llm.ApiFormat.openai, apiFormatForModel("kimi-k2.5"));
    try std.testing.expectEqual(llm.ApiFormat.anthropic, apiFormatForModel("minimax-m2.5"));
}
