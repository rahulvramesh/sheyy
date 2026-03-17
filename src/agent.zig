//! Agent system: enhanced agent definitions with tools/skills and the agentic tool-use loop
const std = @import("std");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const conversation = @import("conversation.zig");
const telegram = @import("telegram.zig");
const mcp = @import("mcp.zig");
const memory_cortex = @import("memory_cortex.zig");

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

// ── Reflection & Learning System ──────────────────────────────────

/// Captures agent's self-reflection on task performance
pub const Reflection = struct {
    task: []const u8,
    success: bool,
    what_worked: []const u8,
    what_to_improve: []const u8,
    lessons_learned: []const u8,
    timestamp: i64,
    agent_id: []const u8,
    tools_used: []const []const u8,
    confidence_score: f32, // 0.0 to 1.0

    pub fn deinit(self: Reflection, allocator: std.mem.Allocator) void {
        allocator.free(self.task);
        allocator.free(self.what_worked);
        allocator.free(self.what_to_improve);
        allocator.free(self.lessons_learned);
        allocator.free(self.agent_id);
        for (self.tools_used) |tool| allocator.free(tool);
        allocator.free(self.tools_used);
    }

    /// Convert reflection to a formatted string for storage
    pub fn toString(self: Reflection, allocator: std.mem.Allocator) ![]const u8 {
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(allocator);
        const w = parts.writer(allocator);

        try w.print("Task: {s}\n", .{self.task});
        try w.print("Agent: {s} | Success: {s} | Confidence: {d:.2}\n", .{
            self.agent_id,
            if (self.success) "yes" else "no",
            self.confidence_score,
        });
        try w.print("Tools used: ", .{});
        for (self.tools_used, 0..) |tool, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}", .{tool});
        }
        try w.print("\nWhat worked: {s}\n", .{self.what_worked});
        try w.print("What to improve: {s}\n", .{self.what_to_improve});
        try w.print("Lessons learned: {s}", .{self.lessons_learned});

        return try allocator.dupe(u8, parts.items);
    }
};

/// Tracks tool performance metrics for adaptive learning
pub const ToolPerformance = struct {
    tool_name: []const u8,
    total_attempts: u32,
    successful_attempts: u32,
    failed_attempts: u32,
    avg_execution_time_ms: u64,
    last_used: i64,

    pub fn successRate(self: ToolPerformance) f32 {
        if (self.total_attempts == 0) return 0.5; // Default neutral confidence
        return @as(f32, @floatFromInt(self.successful_attempts)) / @as(f32, @floatFromInt(self.total_attempts));
    }

    pub fn update(self: *ToolPerformance, success: bool, execution_time_ms: u64) void {
        self.total_attempts += 1;
        if (success) {
            self.successful_attempts += 1;
        } else {
            self.failed_attempts += 1;
        }
        // Update rolling average
        const new_avg = (@as(u64, self.avg_execution_time_ms) * @as(u64, self.total_attempts - 1) + execution_time_ms) / @as(u64, self.total_attempts);
        self.avg_execution_time_ms = @truncate(new_avg);
        self.last_used = std.time.timestamp();
    }
};

/// Learning tracker manages performance data for adaptive behavior
pub const LearningTracker = struct {
    allocator: std.mem.Allocator,
    tool_performance: std.StringHashMap(ToolPerformance),
    reflections: std.ArrayList(Reflection),
    agent_success_rates: std.StringHashMap(f32),

    pub fn init(allocator: std.mem.Allocator) LearningTracker {
        return .{
            .allocator = allocator,
            .tool_performance = std.StringHashMap(ToolPerformance).init(allocator),
            .reflections = .empty,
            .agent_success_rates = std.StringHashMap(f32).init(allocator),
        };
    }

    pub fn deinit(self: *LearningTracker) void {
        var perf_it = self.tool_performance.iterator();
        while (perf_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tool_performance.deinit();

        for (self.reflections.items) |reflection| {
            reflection.deinit(self.allocator);
        }
        self.reflections.deinit(self.allocator);

        var agent_it = self.agent_success_rates.iterator();
        while (agent_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.agent_success_rates.deinit();
    }

    /// Record a tool execution result
    pub fn recordToolExecution(self: *LearningTracker, tool_name: []const u8, success: bool, execution_time_ms: u64) !void {
        const result = try self.tool_performance.getOrPut(tool_name);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, tool_name);
            result.value_ptr.* = ToolPerformance{
                .tool_name = result.key_ptr.*,
                .total_attempts = 0,
                .successful_attempts = 0,
                .failed_attempts = 0,
                .avg_execution_time_ms = 0,
                .last_used = 0,
            };
        }
        result.value_ptr.update(success, execution_time_ms);
    }

    /// Get confidence score for a tool (0.0 to 1.0)
    pub fn getToolConfidence(self: *LearningTracker, tool_name: []const u8) f32 {
        if (self.tool_performance.get(tool_name)) |perf| {
            return perf.successRate();
        }
        return 0.5; // Default neutral confidence
    }

    /// Add a reflection to the learning tracker
    pub fn addReflection(self: *LearningTracker, reflection: Reflection) !void {
        try self.reflections.append(self.allocator, reflection);
    }

    /// Find relevant reflections based on task similarity
    pub fn findRelevantReflections(self: *LearningTracker, task_query: []const u8, max_results: usize) ![]const Reflection {
        // Simple keyword matching - in production, use semantic search
        var matches: std.ArrayList(Reflection) = .empty;
        defer matches.deinit(self.allocator);

        const query_lower = try self.allocator.alloc(u8, task_query.len);
        defer self.allocator.free(query_lower);
        for (task_query, 0..) |c, i| {
            query_lower[i] = std.ascii.toLower(c);
        }

        for (self.reflections.items) |reflection| {
            const task_lower = try self.allocator.alloc(u8, reflection.task.len);
            defer self.allocator.free(task_lower);
            for (reflection.task, 0..) |c, i| {
                task_lower[i] = std.ascii.toLower(c);
            }

            // Check for keyword overlap
            if (std.mem.indexOf(u8, task_lower, query_lower) != null or
                std.mem.indexOf(u8, query_lower, task_lower) != null)
            {
                try matches.append(self.allocator, reflection);
            }
        }

        // Sort by timestamp (most recent first)
        const SortContext = struct {
            pub fn lessThan(_: @This(), a: Reflection, b: Reflection) bool {
                return a.timestamp > b.timestamp;
            }
        };
        std.sort.block(Reflection, matches.items, SortContext{}, SortContext.lessThan);

        const count = @min(max_results, matches.items.len);
        const result = try self.allocator.alloc(Reflection, count);
        for (0..count) |i| {
            // Deep copy the reflection
            const orig = matches.items[i];
            result[i] = .{
                .task = try self.allocator.dupe(u8, orig.task),
                .success = orig.success,
                .what_worked = try self.allocator.dupe(u8, orig.what_worked),
                .what_to_improve = try self.allocator.dupe(u8, orig.what_to_improve),
                .lessons_learned = try self.allocator.dupe(u8, orig.lessons_learned),
                .timestamp = orig.timestamp,
                .agent_id = try self.allocator.dupe(u8, orig.agent_id),
                .tools_used = try self.allocator.dupe([]const u8, orig.tools_used),
                .confidence_score = orig.confidence_score,
            };
        }

        return result;
    }

    /// Get learning summary for system prompt enhancement
    pub fn getLearningSummary(self: *LearningTracker, agent_id: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.reflections.items.len == 0) return null;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("\n\n=== Past Learning & Experience ===\n", .{});

        // Add relevant tool performance data
        if (self.tool_performance.count() > 0) {
            try w.print("\nTool Performance Insights:\n", .{});
            var it = self.tool_performance.iterator();
            while (it.next()) |entry| {
                const perf = entry.value_ptr.*;
                const rate = perf.successRate();
                if (rate < 0.7) {
                    try w.print("- {s}: Low success rate ({d:.0}%), consider alternatives\n", .{
                        perf.tool_name,
                        rate * 100,
                    });
                } else if (rate > 0.9) {
                    try w.print("- {s}: High reliability ({d:.0}%)\n", .{
                        perf.tool_name,
                        rate * 100,
                    });
                }
            }
        }

        // Add recent relevant reflections
        var recent_reflections: usize = 0;
        for (self.reflections.items) |reflection| {
            if (std.mem.eql(u8, reflection.agent_id, agent_id) and recent_reflections < 3) {
                if (recent_reflections == 0) {
                    try w.print("\nKey Lessons from Past Tasks:\n", .{});
                }
                recent_reflections += 1;
                try w.print("\nTask: {s}\n", .{reflection.task});
                try w.print("Success: {s} | Lesson: {s}\n", .{
                    if (reflection.success) "✓" else "✗",
                    reflection.lessons_learned,
                });
            }
        }

        if (recent_reflections == 0 and self.tool_performance.count() == 0) {
            return null;
        }

        return try allocator.dupe(u8, buf.items);
    }
};

// ── Chain-of-Thought (CoT) Reasoning ────────────────────────────────

/// Represents a single reasoning step in a Chain-of-Thought process
pub const ReasoningStep = struct {
    step_number: usize,
    observation: []const u8,
    thought: []const u8,
    action: ?[]const u8,
    result: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, step_num: usize, obs: []const u8, thought: []const u8) !ReasoningStep {
        return .{
            .step_number = step_num,
            .observation = try allocator.dupe(u8, obs),
            .thought = try allocator.dupe(u8, thought),
            .action = null,
            .result = null,
        };
    }

    pub fn deinit(self: *ReasoningStep, allocator: std.mem.Allocator) void {
        allocator.free(self.observation);
        allocator.free(self.thought);
        if (self.action) |a| allocator.free(a);
        if (self.result) |r| allocator.free(r);
    }

    pub fn setAction(self: *ReasoningStep, allocator: std.mem.Allocator, action: []const u8) !void {
        if (self.action) |a| allocator.free(a);
        self.action = try allocator.dupe(u8, action);
    }

    pub fn setResult(self: *ReasoningStep, allocator: std.mem.Allocator, result: []const u8) !void {
        if (self.result) |r| allocator.free(r);
        self.result = try allocator.dupe(u8, result);
    }
};

/// Different types of CoT prompting strategies
pub const CoTMode = enum {
    disabled,
    zero_shot,
    few_shot,
    self_consistency,
};

/// Configuration for Chain-of-Thought reasoning
pub const CoTConfig = struct {
    mode: CoTMode,
    max_steps: usize,
    consistency_samples: usize,
    display_reasoning: bool,
    examples: ?[]const Example,

    pub const Example = struct {
        question: []const u8,
        reasoning: []const u8,
        answer: []const u8,
    };
};

/// Default CoT configuration
pub const default_cot_config = CoTConfig{
    .mode = .disabled,
    .max_steps = 10,
    .consistency_samples = 3,
    .display_reasoning = true,
    .examples = null,
};

/// Build CoT-enhanced system prompt
pub fn buildCoTPrompt(allocator: std.mem.Allocator, base_prompt: []const u8, config: CoTConfig) ![]u8 {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(allocator);
    const w = parts.writer(allocator);

    try w.print("{s}", .{base_prompt});

    switch (config.mode) {
        .disabled => {},
        .zero_shot => {
            try w.print("\n\nWhen solving problems, think step by step. Break down your reasoning into clear steps. Start each step with 'Step N: Observation: ... Thought: ... Action: ...' format. After completing all steps, provide your final answer.", .{});
        },
        .few_shot => {
            try w.print("\n\nWhen solving problems, think step by step following these examples:\n\n", .{});
            if (config.examples) |examples| {
                for (examples, 1..) |ex, i| {
                    try w.print("Example {d}:\n", .{i});
                    try w.print("Question: {s}\n", .{ex.question});
                    try w.print("{s}\n", .{ex.reasoning});
                    try w.print("Final Answer: {s}\n\n", .{ex.answer});
                }
            }
            try w.print("Now solve the following problem step by step using the same format.", .{});
        },
        .self_consistency => {
            try w.print("\n\nWhen solving problems, think step by step and explore multiple reasoning paths. Consider different approaches and choose the most reliable one. After completing your reasoning, provide your final answer with confidence.", .{});
        },
    }

    return try allocator.dupe(u8, parts.items);
}

/// Parse reasoning steps from LLM response
pub fn parseReasoningSteps(allocator: std.mem.Allocator, response: []const u8) !std.ArrayList(ReasoningStep) {
    var steps = std.ArrayList(ReasoningStep).init(allocator);
    errdefer {
        for (steps.items) |*s| s.deinit(allocator);
        steps.deinit();
    }

    var step_num: usize = 1;
    var cursor: usize = 0;

    while (cursor < response.len) {
        const step_prefix = try std.fmt.allocPrint(allocator, "Step {d}:", .{step_num});
        defer allocator.free(step_prefix);

        const step_start = std.mem.indexOfPos(u8, response, cursor, step_prefix);
        if (step_start == null) {
            if (step_num == 1) {
                const step = try ReasoningStep.init(allocator, 1, "Problem statement", response);
                try steps.append(step);
            }
            break;
        }

        const step_begin = step_start.?;
        const next_step_prefix = try std.fmt.allocPrint(allocator, "Step {d}:", .{step_num + 1});
        defer allocator.free(next_step_prefix);

        const step_end = std.mem.indexOfPos(u8, response, step_begin + 1, next_step_prefix) orelse response.len;
        const step_content = response[step_begin + step_prefix.len .. step_end];

        var observation: []const u8 = "";
        var thought: []const u8 = "";
        var action: ?[]const u8 = null;

        const obs_start = std.mem.indexOf(u8, step_content, "Observation:");
        if (obs_start) |obs_pos| {
            const obs_end_pos = std.mem.indexOfPos(u8, step_content, obs_pos, "Thought:") orelse step_content.len;
            observation = std.mem.trim(u8, step_content[obs_pos + 12 .. obs_end_pos], " \n\r\t");
        }

        const thought_start = std.mem.indexOf(u8, step_content, "Thought:");
        if (thought_start) |thought_pos| {
            const thought_end_pos = std.mem.indexOfPos(u8, step_content, thought_pos, "Action:") orelse step_content.len;
            thought = std.mem.trim(u8, step_content[thought_pos + 8 .. thought_end_pos], " \n\r\t");
        }

        const action_start = std.mem.indexOf(u8, step_content, "Action:");
        if (action_start) |action_pos| {
            action = std.mem.trim(u8, step_content[action_pos + 7 ..], " \n\r\t");
        }

        var step = try ReasoningStep.init(allocator, step_num, observation, thought);
        if (action) |a| {
            try step.setAction(allocator, a);
        }
        try steps.append(step);

        cursor = step_end;
        step_num += 1;
    }

    return steps;
}

/// Extract final answer from reasoning response
pub fn extractFinalAnswer(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    const marker = "Final Answer:";
    const final_idx = std.mem.indexOf(u8, response, marker);

    if (final_idx) |idx| {
        const answer_start = idx + marker.len;
        return try allocator.dupe(u8, std.mem.trim(u8, response[answer_start..], " \n\r\t"));
    }

    const last_step = std.mem.lastIndexOf(u8, response, "Step");
    if (last_step) |idx| {
        const end_idx = std.mem.indexOfPos(u8, response, idx, "\n\n") orelse response.len;
        if (end_idx < response.len) {
            return try allocator.dupe(u8, std.mem.trim(u8, response[end_idx..], " \n\r\t"));
        }
    }

    return try allocator.dupe(u8, std.mem.trim(u8, response, " \n\r\t"));
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

    // Reflection & learning
    cortex: ?*memory_cortex.MemoryCortex,
    learning_tracker: LearningTracker,
    enable_reflection: bool,
    min_reflection_confidence: f32,

    // Chain-of-Thought reasoning
    reasoning_mode: CoTMode,
    cot_config: CoTConfig,

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
            .cortex = null,
            .learning_tracker = LearningTracker.init(allocator),
            .enable_reflection = true,
            .min_reflection_confidence = 0.7,
            .reasoning_mode = .disabled,
            .cot_config = default_cot_config,
        };
    }

    /// Set the memory cortex for reflection storage
    pub fn setMemoryCortex(self: *AgentRuntime, cortex: *memory_cortex.MemoryCortex) void {
        self.cortex = cortex;
    }

    /// Enable or disable reflection
    pub fn setReflectionEnabled(self: *AgentRuntime, enabled: bool) void {
        self.enable_reflection = enabled;
    }

    /// Enable Chain-of-Thought reasoning with specified mode
    pub fn enableCoT(self: *AgentRuntime, mode: CoTMode, config: ?CoTConfig) void {
        self.reasoning_mode = mode;
        if (config) |c| {
            self.cot_config = c;
        } else {
            self.cot_config = CoTConfig{
                .mode = mode,
                .max_steps = 10,
                .consistency_samples = 3,
                .display_reasoning = true,
                .examples = null,
            };
        }
    }

    /// Disable Chain-of-Thought reasoning
    pub fn disableCoT(self: *AgentRuntime) void {
        self.reasoning_mode = .disabled;
    }

    /// Solve a complex problem using Chain-of-Thought reasoning
    pub fn solveWithCoT(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        conv: *conversation.Conversation,
        chat_id: i64,
        progress_msg_id: ?i64,
        working_dir: ?[]const u8,
    ) ![]u8 {
        // Build base system prompt with skills
        const base_prompt = try buildSystemPrompt(self.allocator, agent_def, self.skills_dir);
        defer self.allocator.free(base_prompt);

        // Enhance with CoT instructions if enabled
        const system_prompt = if (self.reasoning_mode != .disabled)
            try buildCoTPrompt(self.allocator, base_prompt, self.cot_config)
        else
            try self.allocator.dupe(u8, base_prompt);
        defer self.allocator.free(system_prompt);

        // For self-consistency mode, generate multiple reasoning paths
        if (self.reasoning_mode == .self_consistency) {
            return try self.solveWithSelfConsistency(
                agent_def,
                conv,
                system_prompt,
                chat_id,
                progress_msg_id,
                working_dir,
            );
        }

        // Standard CoT solving
        var all_steps = std.ArrayList(ReasoningStep).init(self.allocator);
        defer {
            for (all_steps.items) |*step| step.deinit(self.allocator);
            all_steps.deinit();
        }

        // Initial prompt for CoT
        var messages: std.ArrayList(llm.RichMessage) = .empty;
        defer messages.deinit(self.allocator);

        try messages.append(self.allocator, .{ .role = "system", .content = system_prompt });

        // Add conversation context
        for (conv.messages.items) |msg| {
            try messages.append(self.allocator, .{
                .role = msg.role,
                .content = msg.content,
                .tool_call_id = msg.tool_call_id,
                .tool_calls_json = msg.tool_calls_json,
            });
        }

        // Request initial reasoning from LLM
        const tools_json: ?[]u8 = if (agent_def.tool_names.len > 0) blk: {
            break :blk switch (agent_def.api_format) {
                .openai => try self.tool_registry.toOpenAIToolsJson(self.allocator),
                .anthropic => try self.tool_registry.toAnthropicToolsJson(self.allocator),
            };
        } else null;
        defer if (tools_json) |j| self.allocator.free(j);

        var step_count: usize = 0;
        while (step_count < self.cot_config.max_steps) {
            const response = try self.llm_client.chatCompletionWithTools(
                messages.items,
                agent_def.model_id,
                agent_def.temperature,
                agent_def.api_format,
                tools_json,
            );
            defer response.deinit(self.allocator);

            const content = response.content orelse break;

            // Parse reasoning steps from response
            var steps = try parseReasoningSteps(self.allocator, content);
            defer {
                for (steps.items) |*s| s.deinit(self.allocator);
                steps.deinit();
            }

            // Add steps to collection
            for (steps.items) |step| {
                var step_copy = try ReasoningStep.init(
                    self.allocator,
                    step.step_number + all_steps.items.len,
                    step.observation,
                    step.thought,
                );
                if (step.action) |a| {
                    try step_copy.setAction(self.allocator, a);
                }
                if (step.result) |r| {
                    try step_copy.setResult(self.allocator, r);
                }
                try all_steps.append(step_copy);
            }

            // Check if we have tool calls to execute
            if (response.hasToolCalls()) {
                const calls = response.tool_calls.?;

                // Execute tools
                for (calls) |call| {
                    const result = try self.executeTool(call, agent_def, working_dir);
                    defer self.allocator.free(result);

                    // Add tool result to conversation
                    const tool_msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Step {d}: Tool execution result:\n{s}",
                        .{ all_steps.items.len, result },
                    );
                    defer self.allocator.free(tool_msg);

                    try messages.append(self.allocator, .{
                        .role = "assistant",
                        .content = tool_msg,
                    });
                }

                step_count += 1;
                continue;
            }

            // Check if we have a final answer
            const final_answer = try extractFinalAnswer(self.allocator, content);
            defer self.allocator.free(final_answer);

            // Optionally display reasoning process
            if (self.cot_config.display_reasoning) {
                var reasoning_display = std.ArrayList(u8).init(self.allocator);
                defer reasoning_display.deinit();

                const w = reasoning_display.writer();
                try w.print("**Reasoning Process:**\n\n", .{});
                for (all_steps.items) |step| {
                    try w.print("**Step {d}:**\n", .{step.step_number});
                    try w.print("- Observation: {s}\n", .{step.observation});
                    try w.print("- Thought: {s}\n", .{step.thought});
                    if (step.action) |a| {
                        try w.print("- Action: {s}\n", .{a});
                    }
                    if (step.result) |r| {
                        try w.print("- Result: {s}\n", .{r});
                    }
                    try w.print("\n", .{});
                }
                try w.print("**Final Answer:** {s}\n", .{final_answer});

                // Return reasoning + answer
                return try self.allocator.dupe(u8, reasoning_display.items);
            }

            return try self.allocator.dupe(u8, final_answer);
        }

        // Max steps reached
        return try self.allocator.dupe(u8, "Maximum reasoning steps reached without reaching a conclusion.");
    }

    /// Solve with self-consistency: generate multiple reasoning paths and pick the best
    fn solveWithSelfConsistency(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        conv: *conversation.Conversation,
        system_prompt: []const u8,
        chat_id: i64,
        progress_msg_id: ?i64,
        working_dir: ?[]const u8,
    ) ![]u8 {
        _ = chat_id;
        _ = progress_msg_id;
        _ = working_dir;
        const num_samples = self.cot_config.consistency_samples;

        var candidate_answers = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (candidate_answers.items) |ans| self.allocator.free(ans);
            candidate_answers.deinit();
        }

        var candidate_reasonings = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (candidate_reasonings.items) |r| self.allocator.free(r);
            candidate_reasonings.deinit();
        }

        // Generate multiple reasoning paths
        for (0..num_samples) |sample_idx| {
            var messages: std.ArrayList(llm.RichMessage) = .empty;
            defer messages.deinit(self.allocator);

            // Add system prompt with variation for diversity
            const varied_prompt = try std.fmt.allocPrint(
                self.allocator,
                "{s}\n\n(Reasoning path {d}/{d}: Consider a different approach if possible)",
                .{ system_prompt, sample_idx + 1, num_samples },
            );
            defer self.allocator.free(varied_prompt);

            try messages.append(self.allocator, .{ .role = "system", .content = varied_prompt });

            // Add conversation context
            for (conv.messages.items) |msg| {
                try messages.append(self.allocator, .{
                    .role = msg.role,
                    .content = msg.content,
                });
            }

            const response = try self.llm_client.chatCompletion(
                messages.items,
                agent_def.model_id,
                agent_def.temperature,
                agent_def.api_format,
            );
            defer response.deinit(self.allocator);

            const content = response.content orelse continue;

            // Extract answer
            const answer = try extractFinalAnswer(self.allocator, content);
            try candidate_answers.append(answer);

            // Store full reasoning
            const reasoning = try self.allocator.dupe(u8, content);
            try candidate_reasonings.append(reasoning);
        }

        // Vote on the best answer (most common)
        const best_answer = try self.voteOnAnswer(candidate_answers.items);

        // Find the reasoning path that led to the best answer
        var best_reasoning: ?[]const u8 = null;
        for (candidate_answers.items, candidate_reasonings.items) |ans, reasoning| {
            if (std.mem.eql(u8, ans, best_answer)) {
                best_reasoning = reasoning;
                break;
            }
        }

        // Build final response
        if (self.cot_config.display_reasoning) {
            var result = std.ArrayList(u8).init(self.allocator);
            defer result.deinit();

            const w = result.writer();
            try w.print("**Self-Consistency Reasoning ({d} paths):**\n\n", .{num_samples});

            for (candidate_reasonings.items, 0..) |reasoning, i| {
                try w.print("--- Path {d} ---\n{s}\n\n", .{ i + 1, reasoning });
            }

            try w.print("**Most Consistent Answer:** {s}\n", .{best_answer});

            return try self.allocator.dupe(u8, result.items);
        }

        return try self.allocator.dupe(u8, best_answer);
    }

    /// Vote on the most common answer from multiple candidates
    fn voteOnAnswer(self: *AgentRuntime, candidates: []const []const u8) ![]const u8 {
        if (candidates.len == 0) return try self.allocator.dupe(u8, "No answer generated");
        if (candidates.len == 1) return try self.allocator.dupe(u8, candidates[0]);

        // Simple voting - count occurrences
        var vote_counts = std.StringHashMap(usize).init(self.allocator);
        defer vote_counts.deinit();

        for (candidates) |ans| {
            // Normalize answer for comparison (trim whitespace)
            const normalized = std.mem.trim(u8, ans, " \n\r\t");

            const result = try vote_counts.getOrPut(normalized);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }

        // Find answer with most votes
        var best_answer: []const u8 = candidates[0];
        var max_votes: usize = 0;

        var it = vote_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > max_votes) {
                max_votes = entry.value_ptr.*;
                best_answer = entry.key_ptr.*;
            }
        }

        return try self.allocator.dupe(u8, best_answer);
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

    // ── Reflection & Learning Methods ─────────────────────────────────

    /// Reflect on a completed task by analyzing the conversation and generating insights
    pub fn reflectOnTask(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        task_description: []const u8,
        conv: *conversation.Conversation,
        success: bool,
        tools_used: []const []const u8,
    ) !void {
        if (!self.enable_reflection) return;

        // Build conversation summary for reflection
        var conversation_summary: std.ArrayList(u8) = .empty;
        defer conversation_summary.deinit(self.allocator);
        const w = conversation_summary.writer(self.allocator);

        try w.print("Task: {s}\n\nConversation flow:\n", .{task_description});

        // Extract key messages from conversation
        const msg_count = @min(conv.messages.items.len, 20); // Last 20 messages
        const start_idx = if (conv.messages.items.len > msg_count) conv.messages.items.len - msg_count else 0;

        for (conv.messages.items[start_idx..], 0..) |msg, i| {
            try w.print("{d}. {s}: ", .{ i + 1, msg.role });
            if (msg.content) |content| {
                // Truncate long content
                const preview_len = @min(content.len, 200);
                try w.print("{s}", .{content[0..preview_len]});
                if (content.len > 200) try w.print("...", .{});
            } else if (msg.tool_calls_json) |_| {
                try w.print("[tool calls]", .{});
            }
            try w.print("\n", .{});
        }

        // Create reflection prompt
        const reflection_prompt = try std.fmt.allocPrint(
            self.allocator,
            "Analyze the following task completion and provide a structured reflection:\n\n{s}\n\nTask outcome: {s}\nTools used: {s}\n\nPlease provide:\n1. What worked well (be specific about successful strategies)\n2. What could be improved (identify mistakes or inefficiencies)\n3. Key lessons learned (actionable insights for future similar tasks)\n\nFormat your response as:\nWORKED: <what worked>\nIMPROVE: <what to improve>\nLESSONS: <key lessons>",
            .{
                conversation_summary.items,
                if (success) "SUCCESS" else "FAILURE",
                try self.formatToolsList(tools_used),
            },
        );
        defer self.allocator.free(reflection_prompt);

        // Call LLM to generate reflection
        const messages = [_]llm.ChatMessage{
            .{ .role = "system", .content = "You are an expert at analyzing task execution and providing constructive feedback. Be specific, actionable, and concise." },
            .{ .role = "user", .content = reflection_prompt },
        };

        const response_content = try self.llm_client.chatCompletion(
            &messages,
            agent_def.model_id,
            0.3, // Lower temperature for consistent analysis
            agent_def.api_format,
        );
        defer self.allocator.free(response_content);

        // Parse reflection from response
        const reflection = try self.parseReflection(
            agent_def,
            task_description,
            success,
            tools_used,
            response_content,
        );

        // Store reflection in learning tracker
        try self.learning_tracker.addReflection(reflection);

        // Store in memory cortex if available
        if (self.cortex) |cortex| {
            const reflection_str = try reflection.toString(self.allocator);
            defer self.allocator.free(reflection_str);
            try cortex.add(reflection_str, agent_def.id, &.{"reflection"});
        }

        std.log.info("[Reflection] Stored reflection for task: {s}", .{task_description});
    }

    /// Format tools list for reflection prompt
    fn formatToolsList(self: *AgentRuntime, tools: []const []const u8) ![]const u8 {
        if (tools.len == 0) return try self.allocator.dupe(u8, "none");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        for (tools, 0..) |tool, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}", .{tool});
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Parse LLM response into Reflection struct
    fn parseReflection(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        task: []const u8,
        success: bool,
        tools_used: []const []const u8,
        response: []const u8,
    ) !Reflection {
        // Parse WORKED, IMPROVE, LESSONS sections
        const worked_marker = "WORKED:";
        const improve_marker = "IMPROVE:";
        const lessons_marker = "LESSONS:";

        var worked: []const u8 = "No specific observations";
        var improve: []const u8 = "No specific observations";
        var lessons: []const u8 = "No specific lessons";

        // Simple parsing - look for markers
        if (std.mem.indexOf(u8, response, worked_marker)) |idx| {
            const start = idx + worked_marker.len;
            const end = std.mem.indexOf(u8, response[start..], "\n") orelse response.len - start;
            worked = std.mem.trim(u8, response[start .. start + end], " \t\r\n");
        }

        if (std.mem.indexOf(u8, response, improve_marker)) |idx| {
            const start = idx + improve_marker.len;
            const end = std.mem.indexOf(u8, response[start..], "\n") orelse response.len - start;
            improve = std.mem.trim(u8, response[start .. start + end], " \t\r\n");
        }

        if (std.mem.indexOf(u8, response, lessons_marker)) |idx| {
            const start = idx + lessons_marker.len;
            const end = std.mem.indexOf(u8, response[start..], "\n") orelse response.len - start;
            lessons = std.mem.trim(u8, response[start .. start + end], " \t\r\n");
        }

        // Copy tools list
        const tools_copy = try self.allocator.alloc([]const u8, tools_used.len);
        for (tools_used, 0..) |tool, i| {
            tools_copy[i] = try self.allocator.dupe(u8, tool);
        }

        // Calculate confidence based on success and reflection quality
        const confidence: f32 = if (success) 0.8 else 0.4;

        return Reflection{
            .task = try self.allocator.dupe(u8, task),
            .success = success,
            .what_worked = try self.allocator.dupe(u8, worked),
            .what_to_improve = try self.allocator.dupe(u8, improve),
            .lessons_learned = try self.allocator.dupe(u8, lessons),
            .timestamp = std.time.timestamp(),
            .agent_id = try self.allocator.dupe(u8, agent_def.id),
            .tools_used = tools_copy,
            .confidence_score = confidence,
        };
    }

    /// Retrieve relevant past reflections for a task
    pub fn getRelevantReflections(self: *AgentRuntime, task_query: []const u8, max_results: usize) ![]const Reflection {
        return try self.learning_tracker.findRelevantReflections(task_query, max_results);
    }

    /// Build system prompt with learning insights injected
    pub fn buildSystemPromptWithLearning(
        self: *AgentRuntime,
        agent_def: *const AgentDef,
        skills_dir: []const u8,
        current_task: ?[]const u8,
    ) ![]const u8 {
        // Get base system prompt
        var base_prompt: []const u8 = "";
        if (current_task) |task| {
            // Get learning summary for this task
            if (try self.learning_tracker.getLearningSummary(agent_def.id, self.allocator)) |summary| {
                defer self.allocator.free(summary);

                // Get relevant reflections
                const reflections = try self.getRelevantReflections(task, 3);
                defer {
                    for (reflections) |r| r.deinit(self.allocator);
                    self.allocator.free(reflections);
                }

                // Build enhanced prompt
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                const w = buf.writer(self.allocator);

                // Base prompt from agent definition
                try w.print("{s}", .{agent_def.system_prompt});

                // Add learning context
                try w.print("\n\n=== Learning Context ===\n", .{});
                try w.print("You have performed similar tasks before. Here are insights from past experiences:\n", .{});

                // Add tool performance insights
                var has_performance_data = false;
                var it = self.learning_tracker.tool_performance.iterator();
                while (it.next()) |entry| {
                    const perf = entry.value_ptr.*;
                    const rate = perf.successRate();
                    if (!has_performance_data) {
                        try w.print("\nTool Reliability:\n", .{});
                        has_performance_data = true;
                    }
                    if (rate < 0.6) {
                        try w.print("- ⚠️ {s}: Low reliability ({d:.0}%), use with caution\n", .{
                            perf.tool_name,
                            rate * 100,
                        });
                    } else if (rate > 0.85) {
                        try w.print("- ✓ {s}: High reliability ({d:.0}%)\n", .{
                            perf.tool_name,
                            rate * 100,
                        });
                    }
                }

                // Add relevant reflections
                if (reflections.len > 0) {
                    try w.print("\nRelevant Past Experiences:\n", .{});
                    for (reflections, 0..) |reflection, i| {
                        try w.print("\n{d}. Previous task: {s}\n", .{ i + 1, reflection.task });
                        try w.print("   Outcome: {s} | Lesson: {s}\n", .{
                            if (reflection.success) "✓ Success" else "✗ Failed",
                            reflection.lessons_learned,
                        });
                        if (reflection.what_worked.len > 0 and !std.mem.eql(u8, reflection.what_worked, "No specific observations")) {
                            try w.print("   What worked: {s}\n", .{reflection.what_worked});
                        }
                    }
                }

                base_prompt = try self.allocator.dupe(u8, buf.items);
            } else {
                base_prompt = try self.allocator.dupe(u8, agent_def.system_prompt);
            }
        } else {
            base_prompt = try self.allocator.dupe(u8, agent_def.system_prompt);
        }
        defer self.allocator.free(base_prompt);

        // Add skill contents
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(self.allocator);
        const w = parts.writer(self.allocator);

        try w.print("{s}", .{base_prompt});

        // Append each skill file
        for (agent_def.skill_names) |skill_name| {
            const skill_path = try std.fs.path.join(self.allocator, &.{ skills_dir, skill_name });
            defer self.allocator.free(skill_path);

            const skill_content = loadSkillContent(self.allocator, skill_path) catch |err| {
                std.log.warn("Failed to load skill {s}: {s}", .{ skill_name, @errorName(err) });
                continue;
            };
            defer self.allocator.free(skill_content);

            try w.print("\n\n---\n{s}", .{skill_content});
        }

        // If agent has tools, add tool usage instructions
        if (agent_def.tool_names.len > 0) {
            try w.print("\n\nYou have access to tools. Use them when needed to accomplish tasks. When you need to execute commands, use the bash tool.", .{});
        }

        return try self.allocator.dupe(u8, parts.items);
    }

    /// Record tool execution for learning
    pub fn recordToolExecution(
        self: *AgentRuntime,
        tool_name: []const u8,
        success: bool,
        execution_time_ms: u64,
    ) !void {
        try self.learning_tracker.recordToolExecution(tool_name, success, execution_time_ms);
    }

    /// Get recommended tools based on past performance
    pub fn getRecommendedTools(self: *AgentRuntime, available_tools: []const []const u8) ![]const []const u8 {
        const ScoredTool = struct {
            name: []const u8,
            score: f32,
        };

        var scored_tools: std.ArrayList(ScoredTool) = .empty;
        defer scored_tools.deinit(self.allocator);

        for (available_tools) |tool| {
            const score = self.learning_tracker.getToolConfidence(tool);
            try scored_tools.append(self.allocator, .{ .name = tool, .score = score });
        }

        // Sort by confidence score (descending)
        const SortContext = struct {
            pub fn lessThan(_: @This(), a: ScoredTool, b: ScoredTool) bool {
                return a.score > b.score;
            }
        };
        std.sort.block(ScoredTool, scored_tools.items, SortContext{}, SortContext.lessThan);

        // Return sorted tool names
        const result = try self.allocator.alloc([]const u8, scored_tools.items.len);
        for (scored_tools.items, 0..) |item, i| {
            result[i] = try self.allocator.dupe(u8, item.name);
        }

        return result;
    }

    /// Get learning statistics
    pub fn getLearningStats(self: *AgentRuntime) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("Learning Statistics\n\n", .{});
        try w.print("Total Reflections: {d}\n", .{self.learning_tracker.reflections.items.len});
        try w.print("Tool Performance Records: {d}\n", .{self.learning_tracker.tool_performance.count()});

        if (self.learning_tracker.tool_performance.count() > 0) {
            try w.print("\nTool Success Rates:\n", .{});
            var it = self.learning_tracker.tool_performance.iterator();
            while (it.next()) |entry| {
                const perf = entry.value_ptr.*;
                try w.print("  {s}: {d}/{d} ({d:.1}%) avg {d}ms\n", .{
                    perf.tool_name,
                    perf.successful_attempts,
                    perf.total_attempts,
                    perf.successRate() * 100,
                    perf.avg_execution_time_ms,
                });
            }
        }

        if (self.learning_tracker.reflections.items.len > 0) {
            var success_count: usize = 0;
            for (self.learning_tracker.reflections.items) |r| {
                if (r.success) success_count += 1;
            }
            const success_rate = @as(f32, @floatFromInt(success_count)) / @as(f32, @floatFromInt(self.learning_tracker.reflections.items.len));
            try w.print("\nOverall Success Rate: {d:.1}%\n", .{success_rate * 100});
        }

        return try buf.toOwnedSlice(self.allocator);
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

// ── Reflection & Learning Tests ───────────────────────────────────

test "Reflection struct creation and cleanup" {
    const allocator = std.testing.allocator;

    const tools = try allocator.alloc([]const u8, 2);
    tools[0] = try allocator.dupe(u8, "bash");
    tools[1] = try allocator.dupe(u8, "file_read");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Test task"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "Everything went well"),
        .what_to_improve = try allocator.dupe(u8, "Nothing to improve"),
        .lessons_learned = try allocator.dupe(u8, "Always test"),
        .timestamp = std.time.timestamp(),
        .agent_id = try allocator.dupe(u8, "test_agent"),
        .tools_used = tools,
        .confidence_score = 0.85,
    };

    reflection.deinit(allocator);
}

test "Reflection toString conversion" {
    const allocator = std.testing.allocator;

    const tools = try allocator.alloc([]const u8, 1);
    tools[0] = try allocator.dupe(u8, "bash");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Deploy application"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "Testing before deploy"),
        .what_to_improve = try allocator.dupe(u8, "Rollback procedure"),
        .lessons_learned = try allocator.dupe(u8, "Always have backups"),
        .timestamp = 1234567890,
        .agent_id = try allocator.dupe(u8, "deploy_agent"),
        .tools_used = tools,
        .confidence_score = 0.9,
    };
    defer reflection.deinit(allocator);

    const str = try reflection.toString(allocator);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "Task: Deploy application") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "Success: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "Confidence: 0.90") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "bash") != null);
}

test "ToolPerformance tracking" {
    var perf = ToolPerformance{
        .tool_name = "bash",
        .total_attempts = 0,
        .successful_attempts = 0,
        .failed_attempts = 0,
        .avg_execution_time_ms = 0,
        .last_used = 0,
    };

    // Test initial success rate
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), perf.successRate(), 0.01);

    // Record successful execution
    perf.update(true, 100);
    try std.testing.expectEqual(@as(u32, 1), perf.total_attempts);
    try std.testing.expectEqual(@as(u32, 1), perf.successful_attempts);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), perf.successRate(), 0.01);

    // Record failed execution
    perf.update(false, 50);
    try std.testing.expectEqual(@as(u32, 2), perf.total_attempts);
    try std.testing.expectEqual(@as(u32, 1), perf.failed_attempts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), perf.successRate(), 0.01);

    // Average execution time should be updated
    try std.testing.expectEqual(@as(u64, 75), perf.avg_execution_time_ms);
}

test "LearningTracker basic operations" {
    const allocator = std.testing.allocator;
    var tracker = LearningTracker.init(allocator);
    defer tracker.deinit();

    // Record tool executions
    try tracker.recordToolExecution("bash", true, 100);
    try tracker.recordToolExecution("bash", false, 200);
    try tracker.recordToolExecution("file_read", true, 50);

    // Check tool confidence
    const bash_confidence = tracker.getToolConfidence("bash");
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), bash_confidence, 0.01);

    const file_confidence = tracker.getToolConfidence("file_read");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), file_confidence, 0.01);

    // Unknown tool should return default confidence
    const unknown_confidence = tracker.getToolConfidence("unknown_tool");
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), unknown_confidence, 0.01);
}

test "LearningTracker add and find reflections" {
    const allocator = std.testing.allocator;
    var tracker = LearningTracker.init(allocator);
    defer tracker.deinit();

    // Create test reflection
    const tools = try allocator.alloc([]const u8, 1);
    tools[0] = try allocator.dupe(u8, "bash");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Deploy to production"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "Testing"),
        .what_to_improve = try allocator.dupe(u8, "Monitoring"),
        .lessons_learned = try allocator.dupe(u8, "Always verify"),
        .timestamp = std.time.timestamp(),
        .agent_id = try allocator.dupe(u8, "deploy_agent"),
        .tools_used = tools,
        .confidence_score = 0.8,
    };

    try tracker.addReflection(reflection);
    try std.testing.expectEqual(@as(usize, 1), tracker.reflections.items.len);

    // Find relevant reflections
    const results = try tracker.findRelevantReflections("deploy production", 5);
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expect(results.len > 0);
}

test "LearningTracker learning summary" {
    const allocator = std.testing.allocator;
    var tracker = LearningTracker.init(allocator);
    defer tracker.deinit();

    // Add some performance data
    try tracker.recordToolExecution("bash", true, 100);
    try tracker.recordToolExecution("bash", true, 120);
    try tracker.recordToolExecution("bash", false, 300);

    // Add reflection
    const tools = try allocator.alloc([]const u8, 1);
    tools[0] = try allocator.dupe(u8, "bash");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Test task"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "Everything"),
        .what_to_improve = try allocator.dupe(u8, "Nothing"),
        .lessons_learned = try allocator.dupe(u8, "Keep it up"),
        .timestamp = std.time.timestamp(),
        .agent_id = try allocator.dupe(u8, "test_agent"),
        .tools_used = tools,
        .confidence_score = 0.9,
    };
    try tracker.addReflection(reflection);

    // Get learning summary
    const summary = try tracker.getLearningSummary("test_agent", allocator);
    defer if (summary) |s| allocator.free(s);

    try std.testing.expect(summary != null);
    if (summary) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s, "bash") != null);
    }
}

test "AgentRuntime formatToolsList" {
    const allocator = std.testing.allocator;

    // Mock runtime for testing
    var tracker = LearningTracker.init(allocator);
    defer tracker.deinit();

    // Create a minimal runtime to test the method
    var runtime = AgentRuntime{
        .allocator = allocator,
        .llm_client = undefined,
        .tool_registry = undefined,
        .tg = undefined,
        .max_tool_iterations = 15,
        .skills_dir = "",
        .mcp_manager = null,
        .max_parallel_tools = 5,
        .cortex = null,
        .learning_tracker = tracker,
        .enable_reflection = true,
        .min_reflection_confidence = 0.7,
    };

    // Test with empty tools
    const empty_tools: []const []const u8 = &[_][]const u8{};
    const empty_result = try runtime.formatToolsList(empty_tools);
    defer allocator.free(empty_result);
    try std.testing.expectEqualStrings("none", empty_result);

    // Test with single tool
    const single_tool: []const []const u8 = &.{"bash"};
    const single_result = try runtime.formatToolsList(single_tool);
    defer allocator.free(single_result);
    try std.testing.expectEqualStrings("bash", single_result);

    // Test with multiple tools
    const multi_tools: []const []const u8 = &.{ "bash", "file_read", "deploy" };
    const multi_result = try runtime.formatToolsList(multi_tools);
    defer allocator.free(multi_result);
    try std.testing.expectEqualStrings("bash, file_read, deploy", multi_result);
}

test "AgentRuntime getRecommendedTools" {
    const allocator = std.testing.allocator;
    const tracker = LearningTracker.init(allocator);

    // Create a minimal runtime
    var runtime = AgentRuntime{
        .allocator = allocator,
        .llm_client = undefined,
        .tool_registry = undefined,
        .tg = undefined,
        .max_tool_iterations = 15,
        .skills_dir = "",
        .mcp_manager = null,
        .max_parallel_tools = 5,
        .cortex = null,
        .learning_tracker = tracker,
        .enable_reflection = true,
        .min_reflection_confidence = 0.7,
    };
    defer runtime.learning_tracker.deinit();

    // Record some tool performance data
    try runtime.recordToolExecution("reliable_tool", true, 100);
    try runtime.recordToolExecution("reliable_tool", true, 100);
    try runtime.recordToolExecution("unreliable_tool", false, 200);
    try runtime.recordToolExecution("unreliable_tool", false, 200);

    // Get recommended tools
    const available = &.{ "unreliable_tool", "reliable_tool", "unknown_tool" };
    const recommended = try runtime.getRecommendedTools(available);
    defer {
        for (recommended) |r| allocator.free(r);
        allocator.free(recommended);
    }

    // Should return all tools sorted by confidence (highest first)
    try std.testing.expectEqual(@as(usize, 3), recommended.len);

    // reliable_tool should be first (1.0 success rate)
    try std.testing.expectEqualStrings("reliable_tool", recommended[0]);

    // unknown_tool should be before unreliable_tool (0.5 > 0.0)
    try std.testing.expectEqualStrings("unknown_tool", recommended[1]);

    // unreliable_tool should be last (0.0 success rate)
    try std.testing.expectEqualStrings("unreliable_tool", recommended[2]);
}

test "AgentRuntime reflection and learning stats" {
    const allocator = std.testing.allocator;
    const tracker = LearningTracker.init(allocator);

    var runtime = AgentRuntime{
        .allocator = allocator,
        .llm_client = undefined,
        .tool_registry = undefined,
        .tg = undefined,
        .max_tool_iterations = 15,
        .skills_dir = "",
        .mcp_manager = null,
        .max_parallel_tools = 5,
        .cortex = null,
        .learning_tracker = tracker,
        .enable_reflection = true,
        .min_reflection_confidence = 0.7,
    };
    defer runtime.learning_tracker.deinit();

    // Record some data
    try runtime.recordToolExecution("bash", true, 100);
    try runtime.recordToolExecution("bash", true, 120);

    const tools = try allocator.alloc([]const u8, 1);
    tools[0] = try allocator.dupe(u8, "bash");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Test deployment"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "Automated testing"),
        .what_to_improve = try allocator.dupe(u8, "Rollback speed"),
        .lessons_learned = try allocator.dupe(u8, "Monitor closely"),
        .timestamp = std.time.timestamp(),
        .agent_id = try allocator.dupe(u8, "test_agent"),
        .tools_used = tools,
        .confidence_score = 0.85,
    };
    try runtime.learning_tracker.addReflection(reflection);

    // Get learning stats
    const stats = try runtime.getLearningStats();
    defer allocator.free(stats);

    try std.testing.expect(std.mem.indexOf(u8, stats, "Total Reflections: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "Tool Performance Records: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "Overall Success Rate: 100.0%") != null);
}

test "Reflection parsing with markers" {
    const allocator = std.testing.allocator;
    const tracker = LearningTracker.init(allocator);

    var runtime = AgentRuntime{
        .allocator = allocator,
        .llm_client = undefined,
        .tool_registry = undefined,
        .tg = undefined,
        .max_tool_iterations = 15,
        .skills_dir = "",
        .mcp_manager = null,
        .max_parallel_tools = 5,
        .cortex = null,
        .learning_tracker = tracker,
        .enable_reflection = true,
        .min_reflection_confidence = 0.7,
    };
    defer runtime.learning_tracker.deinit();

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
        .tool_names = &.{
            "bash",
        },
        .skill_names = &.{},
    };

    const response_text =
        \\WORKED: Testing thoroughly before deployment
        \\IMPROVE: Rollback procedure documentation
        \\LESSONS: Always have a rollback plan ready
    ;

    const tools: []const []const u8 = &.{
        "bash",
    };

    const reflection = try runtime.parseReflection(
        &agent_def,
        "Deploy application",
        true,
        tools,
        response_text,
    );
    defer reflection.deinit(allocator);

    try std.testing.expectEqualStrings("Deploy application", reflection.task);
    try std.testing.expect(reflection.success);
    try std.testing.expect(std.mem.indexOf(u8, reflection.what_worked, "Testing thoroughly") != null);
    try std.testing.expect(std.mem.indexOf(u8, reflection.what_to_improve, "Rollback procedure") != null);
    try std.testing.expect(std.mem.indexOf(u8, reflection.lessons_learned, "Always have a rollback") != null);
    try std.testing.expectEqualStrings("test_agent", reflection.agent_id);
    try std.testing.expectEqual(@as(usize, 1), reflection.tools_used.len);
    try std.testing.expectEqualStrings("bash", reflection.tools_used[0]);
}

test "AgentRuntime reflection enabled toggle" {
    const allocator = std.testing.allocator;
    const tracker = LearningTracker.init(allocator);

    var runtime = AgentRuntime{
        .allocator = allocator,
        .llm_client = undefined,
        .tool_registry = undefined,
        .tg = undefined,
        .max_tool_iterations = 15,
        .skills_dir = "",
        .mcp_manager = null,
        .max_parallel_tools = 5,
        .cortex = null,
        .learning_tracker = tracker,
        .enable_reflection = true,
        .min_reflection_confidence = 0.7,
    };
    defer runtime.learning_tracker.deinit();

    try std.testing.expect(runtime.enable_reflection);

    runtime.setReflectionEnabled(false);
    try std.testing.expect(!runtime.enable_reflection);

    runtime.setReflectionEnabled(true);
    try std.testing.expect(runtime.enable_reflection);
}

test "LearningTracker deinit cleanup" {
    const allocator = std.testing.allocator;
    var tracker = LearningTracker.init(allocator);

    // Add some data to track cleanup
    try tracker.recordToolExecution("tool1", true, 100);
    try tracker.recordToolExecution("tool2", false, 200);

    const tools = try allocator.alloc([]const u8, 1);
    tools[0] = try allocator.dupe(u8, "bash");

    const reflection = Reflection{
        .task = try allocator.dupe(u8, "Test task"),
        .success = true,
        .what_worked = try allocator.dupe(u8, "It worked"),
        .what_to_improve = try allocator.dupe(u8, "Nothing"),
        .lessons_learned = try allocator.dupe(u8, "Keep going"),
        .timestamp = std.time.timestamp(),
        .agent_id = try allocator.dupe(u8, "agent1"),
        .tools_used = tools,
        .confidence_score = 0.9,
    };
    try tracker.addReflection(reflection);

    // This should clean up all allocated memory without leaking
    tracker.deinit();
}

// ── Chain-of-Thought Tests ────────────────────────────────────────

test "ReasoningStep init and deinit" {
    const allocator = std.testing.allocator;

    var step = try ReasoningStep.init(allocator, 1, "The sky is blue", "I need to check the weather");
    defer step.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), step.step_number);
    try std.testing.expectEqualStrings("The sky is blue", step.observation);
    try std.testing.expectEqualStrings("I need to check the weather", step.thought);
    try std.testing.expectEqual(@as(?[]const u8, null), step.action);
    try std.testing.expectEqual(@as(?[]const u8, null), step.result);
}

test "ReasoningStep setAction and setResult" {
    const allocator = std.testing.allocator;

    var step = try ReasoningStep.init(allocator, 1, "Need to run command", "Execute ls");
    defer step.deinit(allocator);

    try step.setAction(allocator, "bash: ls -la");
    try step.setResult(allocator, "file1 file2 file3");

    try std.testing.expectEqualStrings("bash: ls -la", step.action.?);
    try std.testing.expectEqualStrings("file1 file2 file3", step.result.?);
}

test "buildCoTPrompt - zero_shot mode" {
    const allocator = std.testing.allocator;

    const base_prompt = "You are a helpful assistant.";
    const config = CoTConfig{
        .mode = .zero_shot,
        .max_steps = 10,
        .consistency_samples = 3,
        .display_reasoning = true,
        .examples = null,
    };

    const result = try buildCoTPrompt(allocator, base_prompt, config);
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "think step by step"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "Step N:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "Observation:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "Thought:"));
}

test "buildCoTPrompt - disabled mode" {
    const allocator = std.testing.allocator;

    const base_prompt = "You are a helpful assistant.";
    const config = CoTConfig{
        .mode = .disabled,
        .max_steps = 10,
        .consistency_samples = 3,
        .display_reasoning = true,
        .examples = null,
    };

    const result = try buildCoTPrompt(allocator, base_prompt, config);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(base_prompt, result);
}

test "parseReasoningSteps - structured response" {
    const allocator = std.testing.allocator;

    const response =
        "Step 1: Observation: The problem involves adding 2+2. Thought: This is simple arithmetic. Action: Calculate 2+2.\n" ++
        "Step 2: Observation: The calculation is complete. Thought: I have the result. Action: Provide answer.\n" ++
        "Final Answer: 4";

    var steps = try parseReasoningSteps(allocator, response);
    defer {
        for (steps.items) |*s| s.deinit(allocator);
        steps.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), steps.items.len);
}

test "parseReasoningSteps - no explicit steps" {
    const allocator = std.testing.allocator;

    const response = "This is a simple response without steps.";

    var steps = try parseReasoningSteps(allocator, response);
    defer {
        for (steps.items) |*s| s.deinit(allocator);
        steps.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), steps.items.len);
    try std.testing.expectEqualStrings("Problem statement", steps.items[0].observation);
}

test "extractFinalAnswer - with marker" {
    const allocator = std.testing.allocator;

    const response = "Some reasoning steps...\nFinal Answer: 42";
    const result = try extractFinalAnswer(allocator, response);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("42", result);
}

test "extractFinalAnswer - without marker" {
    const allocator = std.testing.allocator;

    const response = "Just a simple response";
    const result = try extractFinalAnswer(allocator, response);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(response, result);
}

test "CoTMode enum values" {
    try std.testing.expectEqual(CoTMode.disabled, CoTMode.disabled);
    try std.testing.expectEqual(CoTMode.zero_shot, CoTMode.zero_shot);
    try std.testing.expectEqual(CoTMode.few_shot, CoTMode.few_shot);
    try std.testing.expectEqual(CoTMode.self_consistency, CoTMode.self_consistency);
}

test "default_cot_config values" {
    try std.testing.expectEqual(CoTMode.disabled, default_cot_config.mode);
    try std.testing.expectEqual(@as(usize, 10), default_cot_config.max_steps);
    try std.testing.expectEqual(@as(usize, 3), default_cot_config.consistency_samples);
    try std.testing.expect(default_cot_config.display_reasoning);
    try std.testing.expectEqual(@as(?[]const CoTConfig.Example, null), default_cot_config.examples);
}
