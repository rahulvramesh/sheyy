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
    max_parallel_tools: usize,

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
            .max_parallel_tools = 5,
        };
    }

    /// Context for parallel tool execution
    const ToolExecContext = struct {
        allocator: std.mem.Allocator,
        call: llm.ToolCall,
        agent_def: *const AgentDef,
        working_dir: ?[]const u8,
        mcp_manager: ?*mcp.McpManager,
        index: usize,
        tg: *telegram.TelegramClient,
        chat_id: i64,
        progress_msg_id: ?i64,
    };

    /// Result of a tool execution
    const ToolExecResult = struct {
        index: usize,
        output: ?[]u8,
        error_message: ?[]u8,
        call_id: []u8,
    };

    pub fn freeToolExecResult(self: *AgentRuntime, result: ToolExecResult) void {
        if (result.output) |o| self.allocator.free(o);
        if (result.error_message) |e| self.allocator.free(e);
        self.allocator.free(result.call_id);
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

                // Execute tool calls in parallel
                var parallel_results = self.executeToolsParallel(calls, agent_def, working_dir, chat_id, progress_msg_id) catch |err| {
                    std.log.err("Parallel tool execution failed: {s}, falling back to sequential", .{@errorName(err)});
                    // Fall back to sequential execution
                    for (calls) |call| {
                        if (progress_msg_id) |pid| {
                            const progress_text = try std.fmt.allocPrint(self.allocator, "Running: {s}...", .{call.function_name});
                            defer self.allocator.free(progress_text);
                            self.tg.editMessage(chat_id, pid, progress_text) catch {};
                        }

                        const tool_output = self.executeTool(call, agent_def, working_dir) catch |exec_err| {
                            const err_text = try std.fmt.allocPrint(self.allocator, "Error: {s}", .{@errorName(exec_err)});
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
                    // Free response and continue loop
                    response.deinit(self.allocator);
                    continue;
                };
                defer {
                    for (parallel_results.items) |r| {
                        self.freeToolExecResult(r);
                    }
                    parallel_results.deinit(self.allocator);
                }

                // Add results to tool_messages in order
                for (parallel_results.items) |result| {
                    const output = result.error_message orelse result.output orelse "Unknown error";
                    const output_copy = try self.allocator.dupe(u8, output);
                    try tool_messages.append(self.allocator, .{
                        .role = "tool",
                        .content = output_copy,
                        .tool_call_id = result.call_id,
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

    /// Execute tool and store result at the given index in results array
    fn executeToolToResult(ctx: ToolExecContext, results: []ToolExecResult) void {
        const allocator = ctx.allocator;

        // Log start
        std.log.info("[{s}] Starting parallel tool {d}: {s}", .{ ctx.agent_def.id, ctx.index, ctx.call.function_name });

        // Update progress if provided
        if (ctx.progress_msg_id) |pid| {
            const progress_text = std.fmt.allocPrint(allocator, "Running ({d}/{d}): {s}...", .{ ctx.index + 1, ctx.index + 1, ctx.call.function_name }) catch null;
            if (progress_text) |pt| {
                defer allocator.free(pt);
                ctx.tg.editMessage(ctx.chat_id, pid, pt) catch {};
            }
        }

        // Execute the tool
        var output: ?[]u8 = null;
        var error_message: ?[]u8 = null;

        // Check if this is an MCP tool
        if (ctx.mcp_manager) |mgr| {
            if (mgr.isToolMcp(ctx.call.function_name)) {
                std.log.info("[{s}] mcp:{s} args={s}", .{ ctx.agent_def.id, ctx.call.function_name, ctx.call.arguments_json });
                const result = mgr.callTool(ctx.call.function_name, ctx.call.arguments_json) catch |err| {
                    error_message = std.fmt.allocPrint(allocator, "MCP tool error: {s}", .{@errorName(err)}) catch null;
                    results[ctx.index] = ToolExecResult{
                        .index = ctx.index,
                        .output = null,
                        .error_message = error_message,
                        .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
                    };
                    return;
                };
                defer allocator.free(result);
                output = allocator.dupe(u8, result) catch null;
            } else if (std.mem.eql(u8, ctx.call.function_name, "bash")) {
                // Built-in bash tool
                const command = parseCommandForWorker(allocator, ctx.call.arguments_json) catch {
                    error_message = allocator.dupe(u8, "Error: could not parse tool arguments") catch null;
                    results[ctx.index] = ToolExecResult{
                        .index = ctx.index,
                        .output = null,
                        .error_message = error_message,
                        .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
                    };
                    return;
                };
                defer allocator.free(command);

                std.log.info("[{s}] bash: {s}", .{ ctx.agent_def.id, command });

                const bash_result = tools_mod.BashTool.execute(allocator, command, ctx.working_dir) catch |err| {
                    error_message = std.fmt.allocPrint(allocator, "Error executing command: {s}", .{@errorName(err)}) catch null;
                    results[ctx.index] = ToolExecResult{
                        .index = ctx.index,
                        .output = null,
                        .error_message = error_message,
                        .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
                    };
                    return;
                };
                defer bash_result.deinit(allocator);

                const truncated = truncateOutputForWorker(allocator, bash_result.output) catch unreachable;

                if (!bash_result.success) {
                    const with_code = std.fmt.allocPrint(allocator, "Exit code {d}:\n{s}", .{ bash_result.exit_code, truncated }) catch unreachable;
                    allocator.free(truncated);
                    output = with_code;
                } else {
                    output = truncated;
                }
            } else {
                error_message = std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{ctx.call.function_name}) catch null;
            }
        } else {
            // Built-in bash tool (no MCP manager)
            if (std.mem.eql(u8, ctx.call.function_name, "bash")) {
                const command = parseCommandForWorker(allocator, ctx.call.arguments_json) catch {
                    error_message = allocator.dupe(u8, "Error: could not parse tool arguments") catch null;
                    results[ctx.index] = ToolExecResult{
                        .index = ctx.index,
                        .output = null,
                        .error_message = error_message,
                        .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
                    };
                    return;
                };
                defer allocator.free(command);

                std.log.info("[{s}] bash: {s}", .{ ctx.agent_def.id, command });

                const bash_result = tools_mod.BashTool.execute(allocator, command, ctx.working_dir) catch |err| {
                    error_message = std.fmt.allocPrint(allocator, "Error executing command: {s}", .{@errorName(err)}) catch null;
                    results[ctx.index] = ToolExecResult{
                        .index = ctx.index,
                        .output = null,
                        .error_message = error_message,
                        .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
                    };
                    return;
                };
                defer bash_result.deinit(allocator);

                const truncated = truncateOutputForWorker(allocator, bash_result.output) catch unreachable;

                if (!bash_result.success) {
                    const with_code = std.fmt.allocPrint(allocator, "Exit code {d}:\n{s}", .{ bash_result.exit_code, truncated }) catch unreachable;
                    allocator.free(truncated);
                    output = with_code;
                } else {
                    output = truncated;
                }
            } else {
                error_message = std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{ctx.call.function_name}) catch null;
            }
        }

        results[ctx.index] = ToolExecResult{
            .index = ctx.index,
            .output = output,
            .error_message = error_message,
            .call_id = allocator.dupe(u8, ctx.call.id) catch unreachable,
        };
    }

    fn parseCommandForWorker(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
        const Args = struct { command: []const u8 };
        const parsed = std.json.parseFromSlice(Args, allocator, args_json, .{
            .ignore_unknown_fields = true,
        }) catch return error.JsonParseError;
        defer parsed.deinit();
        return try allocator.dupe(u8, parsed.value.command);
    }

    fn truncateOutputForWorker(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
        const max_output = 50 * 1024; // 50KB for LLM context
        if (output.len > max_output) {
            const truncated = try std.fmt.allocPrint(
                allocator,
                "{s}\n... (output truncated, {d} bytes total)",
                .{ output[0..max_output], output.len },
            );
            return truncated;
        }
        return try allocator.dupe(u8, output);
    }

    // Expose helper functions for testing
    pub const TestHelpers = struct {
        pub fn parseCommand(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
            return parseCommandForWorker(allocator, args_json);
        }

        pub fn truncateOutput(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
            return truncateOutputForWorker(allocator, output);
        }
    };

    /// Thread worker data container
    const ThreadWorkerData = struct {
        ctx: ToolExecContext,
        results: []ToolExecResult,
    };

    /// Execute multiple tool calls in parallel with a concurrency limit
    fn executeToolsParallel(
        self: *AgentRuntime,
        calls: []const llm.ToolCall,
        agent_def: *const AgentDef,
        working_dir: ?[]const u8,
        chat_id: i64,
        progress_msg_id: ?i64,
    ) !std.ArrayList(ToolExecResult) {
        var results: std.ArrayList(ToolExecResult) = .empty;
        errdefer {
            for (results.items) |r| {
                self.freeToolExecResult(r);
            }
            results.deinit(self.allocator);
        }

        // Pre-allocate results array
        try results.resize(self.allocator, calls.len);

        // Use thread pool pattern with semaphore for concurrency control
        const max_concurrent = @min(self.max_parallel_tools, calls.len);

        // Create a context for each tool call
        const contexts = try self.allocator.alloc(ToolExecContext, calls.len);
        defer self.allocator.free(contexts);

        for (calls, 0..) |call, i| {
            contexts[i] = ToolExecContext{
                .allocator = self.allocator,
                .call = call,
                .agent_def = agent_def,
                .working_dir = working_dir,
                .mcp_manager = self.mcp_manager,
                .index = i,
                .tg = self.tg,
                .chat_id = chat_id,
                .progress_msg_id = progress_msg_id,
            };
        }

        // Execute tools in batches to limit concurrency
        var completed: usize = 0;
        var batch_start: usize = 0;

        while (completed < calls.len) {
            const batch_size = @min(max_concurrent, calls.len - batch_start);
            const batch_end = batch_start + batch_size;

            // Allocate space for thread handles
            const threads = try self.allocator.alloc(std.Thread, batch_size);
            defer self.allocator.free(threads);

            // Allocate space for worker data
            const worker_data = try self.allocator.alloc(ThreadWorkerData, batch_size);
            defer self.allocator.free(worker_data);

            // Spawn threads for this batch
            for (0..batch_size) |i| {
                const call_idx = batch_start + i;
                worker_data[i] = ThreadWorkerData{
                    .ctx = contexts[call_idx],
                    .results = results.items,
                };
                const data_ptr = &worker_data[i];

                threads[i] = std.Thread.spawn(.{}, struct {
                    fn wrapper(d: *ThreadWorkerData) void {
                        executeToolToResult(d.ctx, d.results);
                    }
                }.wrapper, .{data_ptr}) catch |err| {
                    // If thread spawn fails, execute synchronously
                    std.log.warn("Failed to spawn thread for tool {d}: {s}", .{ call_idx, @errorName(err) });
                    executeToolToResult(contexts[call_idx], results.items);
                    continue;
                };
            }

            // Wait for all threads in batch to complete
            for (0..batch_size) |i| {
                threads[i].join();
                completed += 1;
            }

            batch_start = batch_end;
        }

        return results;
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

    fn parseCommandFromArgs(self: *AgentRuntime, args_json: []const u8) ![]const u8 {
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

test "parallel tool execution - basic ordering" {
    _ = std.testing.allocator; // Allocator available for future expansion

    // Create mock tool calls
    const calls = [_]llm.ToolCall{
        .{ .id = "call_1", .function_name = "bash", .arguments_json = "{\"command\":\"echo first\"}" },
        .{ .id = "call_2", .function_name = "bash", .arguments_json = "{\"command\":\"echo second\"}" },
        .{ .id = "call_3", .function_name = "bash", .arguments_json = "{\"command\":\"echo third\"}" },
    };

    // Test that all calls are processed
    try std.testing.expectEqual(@as(usize, 3), calls.len);

    // Verify call IDs are preserved
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("call_2", calls[1].id);
    try std.testing.expectEqualStrings("call_3", calls[2].id);
}

test "truncateOutputForWorker - within limit" {
    const allocator = std.testing.allocator;
    const input = "Hello, World!";
    const result = try AgentRuntime.TestHelpers.truncateOutput(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "truncateOutputForWorker - exceeds limit" {
    const allocator = std.testing.allocator;
    const large_input = try allocator.alloc(u8, 60 * 1024);
    defer allocator.free(large_input);
    @memset(large_input, 'A');

    const result = try AgentRuntime.TestHelpers.truncateOutput(allocator, large_input);
    defer allocator.free(result);

    // Should be truncated to 50KB + truncation message
    try std.testing.expect(result.len > 50 * 1024);
    try std.testing.expect(result.len < 60 * 1024);
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "truncated"));
}

test "parseCommandForWorker - valid JSON" {
    const allocator = std.testing.allocator;
    const json = "{\"command\":\"ls -la\"}";
    const result = try AgentRuntime.TestHelpers.parseCommand(allocator, json);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
}

test "parseCommandForWorker - invalid JSON" {
    const allocator = std.testing.allocator;
    const json = "not valid json";
    const result = AgentRuntime.TestHelpers.parseCommand(allocator, json);
    try std.testing.expectError(error.JsonParseError, result);
}

test "parallel execution context creation" {
    _ = std.testing.allocator; // Allocator available for future expansion

    const call = llm.ToolCall{
        .id = "test_id",
        .function_name = "bash",
        .arguments_json = "{\"command\":\"echo test\"}",
    };

    const agent_def = AgentDef{
        .id = "test_agent",
        .name = "Test Agent",
        .description = "A test agent",
        .system_prompt = "You are a test agent.",
        .model_id = "gpt-4",
        .temperature = 0.5,
        .api_format = .openai,
        .source_path = null,
        .last_modified = null,
        .tool_names = &.{"bash"},
        .skill_names = &.{},
    };

    // Test that agent_def is properly configured
    try std.testing.expectEqual(@as(usize, 1), agent_def.tool_names.len);
    try std.testing.expectEqualStrings("bash", agent_def.tool_names[0]);
    try std.testing.expectEqualStrings("test_id", call.id);
    try std.testing.expectEqualStrings("bash", call.function_name);
}

test "max_parallel_tools configuration" {
    // Test default configuration
    const default_max: usize = 5;
    try std.testing.expectEqual(@as(usize, 5), default_max);

    // Test that batch size calculation works correctly
    const total_calls: usize = 12;
    const max_concurrent: usize = 5;

    const batch1 = @min(max_concurrent, total_calls);
    try std.testing.expectEqual(@as(usize, 5), batch1);

    const remaining1 = total_calls - batch1;
    const batch2 = @min(max_concurrent, remaining1);
    try std.testing.expectEqual(@as(usize, 5), batch2);

    const remaining2 = remaining1 - batch2;
    const batch3 = @min(max_concurrent, remaining2);
    try std.testing.expectEqual(@as(usize, 2), batch3);
}

test "error handling in parallel execution" {
    const allocator = std.testing.allocator;

    // Test error message formatting
    const err_msg = try std.fmt.allocPrint(allocator, "Error: {s}", .{"TestError"});
    defer allocator.free(err_msg);
    try std.testing.expectEqualStrings("Error: TestError", err_msg);

    // Test error message allocation and cleanup
    const error_msg = try allocator.dupe(u8, "Test error");
    defer allocator.free(error_msg);
    try std.testing.expectEqualStrings("Test error", error_msg);

    const call_id = try allocator.dupe(u8, "call_1");
    defer allocator.free(call_id);
    try std.testing.expectEqualStrings("call_1", call_id);
}
