//! Agent module - Defines the Agent interface and data structures
const std = @import("std");
const commands = @import("commands.zig");

/// Agent status enum
pub const AgentStatus = enum {
    active,
    inactive,
    error_status,
    reloading,
};

/// Agent type - how the agent is loaded
pub const AgentType = enum {
    built_in, // Compiled into the binary
    dynamic, // Loaded from external file
    remote, // External service/API
};

/// Configuration for an agent
pub const AgentConfig = struct {
    name: []const u8,
    description: []const u8,
    model_id: []const u8,
    system_prompt: ?[]const u8,
    temperature: f32 = 0.7,
    max_tokens: i32 = 4096,
    enabled: bool = true,
};

/// Agent metadata
pub const AgentInfo = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    version: []const u8,
    author: ?[]const u8,
    agent_type: AgentType,
    status: AgentStatus,
    config: AgentConfig,
    created_at: i64,
    updated_at: i64,
    last_used: ?i64,
    use_count: u64,
};

/// Agent interface - all agents must implement this
pub const Agent = struct {
    info: AgentInfo,

    // Virtual function pointers for agent behavior
    processMessage: *const fn (
        self: *Agent,
        allocator: std.mem.Allocator,
        message: []const u8,
        context: ?*anyopaque,
    ) AgentError![]u8,

    onLoad: ?*const fn (self: *Agent) AgentError!void = null,
    onUnload: ?*const fn (self: *Agent) AgentError!void = null,
    onReload: ?*const fn (self: *Agent) AgentError!void = null,

    // Optional custom data
    custom_data: ?*anyopaque = null,

    const Self = @This();

    /// Process a message through this agent
    pub fn process(self: *Self, allocator: std.mem.Allocator, message: []const u8, context: ?*anyopaque) AgentError![]u8 {
        const result = try self.processMessage(self, allocator, message, context);
        self.info.use_count += 1;
        self.info.last_used = std.time.timestamp();
        return result;
    }

    /// Load the agent
    pub fn load(self: *Self) AgentError!void {
        if (self.onLoad) |onLoad| {
            try onLoad(self);
        }
        self.info.status = .active;
        self.info.updated_at = std.time.timestamp();
    }

    /// Unload the agent
    pub fn unload(self: *Self) AgentError!void {
        if (self.onUnload) |onUnload| {
            try onUnload(self);
        }
        self.info.status = .inactive;
    }

    /// Reload the agent
    pub fn reload(self: *Self) AgentError!void {
        self.info.status = .reloading;
        if (self.onReload) |onReload| {
            try onReload(self);
        }
        self.info.status = .active;
        self.info.updated_at = std.time.timestamp();
    }

    /// Check if agent is active
    pub fn isActive(self: *Self) bool {
        return self.info.status == .active;
    }

    /// Create a basic built-in agent
    pub fn createBuiltIn(
        allocator: std.mem.Allocator,
        id: []const u8,
        name: []const u8,
        description: []const u8,
        config: AgentConfig,
        processor: *const fn (*Agent, std.mem.Allocator, []const u8, ?*anyopaque) AgentError![]u8,
    ) !*Agent {
        const agent = try allocator.create(Agent);
        errdefer allocator.destroy(agent);

        const now = std.time.timestamp();

        // Duplicate all strings in config to avoid dangling pointers
        const config_name = try allocator.dupe(u8, config.name);
        errdefer allocator.free(config_name);

        const config_description = try allocator.dupe(u8, config.description);
        errdefer allocator.free(config_description);

        const config_model_id = try allocator.dupe(u8, config.model_id);
        errdefer allocator.free(config_model_id);

        const config_system_prompt: ?[]const u8 = if (config.system_prompt) |prompt|
            try allocator.dupe(u8, prompt)
        else
            null;
        errdefer if (config_system_prompt) |p| allocator.free(p);

        agent.* = Agent{
            .info = AgentInfo{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, description),
                .version = "1.0.0",
                .author = null,
                .agent_type = .built_in,
                .status = .inactive,
                .config = .{
                    .name = config_name,
                    .description = config_description,
                    .model_id = config_model_id,
                    .system_prompt = config_system_prompt,
                    .temperature = config.temperature,
                    .max_tokens = config.max_tokens,
                    .enabled = config.enabled,
                },
                .created_at = now,
                .updated_at = now,
                .last_used = null,
                .use_count = 0,
            },
            .processMessage = processor,
            .onLoad = null,
            .onUnload = null,
            .onReload = null,
            .custom_data = null,
        };

        return agent;
    }

    /// Free an agent
    pub fn destroy(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.info.id);
        allocator.free(self.info.name);
        allocator.free(self.info.description);
        if (self.info.author) |author| {
            allocator.free(author);
        }
        // Free config strings
        allocator.free(self.info.config.name);
        allocator.free(self.info.config.description);
        allocator.free(self.info.config.model_id);
        if (self.info.config.system_prompt) |prompt| {
            allocator.free(prompt);
        }
        allocator.destroy(self);
    }
};

/// Agent error types
pub const AgentError = error{
    InvalidAgent,
    AgentNotFound,
    AgentAlreadyExists,
    AgentNotActive,
    LoadFailed,
    UnloadFailed,
    ReloadFailed,
    ProcessFailed,
    OutOfMemory,
    ConfigError,
};

/// Agent capabilities - what an agent can do
pub const AgentCapabilities = struct {
    supports_streaming: bool = false,
    supports_tools: bool = false,
    supports_vision: bool = false,
    supports_memory: bool = false,
    supports_multimodal: bool = false,
};

/// Message context passed to agents
pub const MessageContext = struct {
    user_id: i64,
    chat_id: i64,
    message_id: i64,
    thread_id: ?[]const u8,
    conversation_history: ?[]const u8,
};

/// Agent event types for callbacks
pub const AgentEvent = enum {
    loaded,
    unloaded,
    reloaded,
    message_received,
    message_sent,
    agent_error,
};

/// Agent event handler type
pub const AgentEventHandler = *const fn (event: AgentEvent, agent_id: []const u8, data: ?*anyopaque) void;

test "Agent basic operations" {
    const allocator = std.testing.allocator;

    const config = AgentConfig{
        .name = "Test Agent",
        .description = "A test agent",
        .model_id = "test-model",
    };

    const TestProcessor = struct {
        fn process(agent: *Agent, alloc: std.mem.Allocator, msg: []const u8, ctx: ?*anyopaque) AgentError![]u8 {
            _ = agent;
            _ = ctx;
            return alloc.dupe(u8, msg) catch return AgentError.OutOfMemory;
        }
    };

    var agent = try Agent.createBuiltIn(
        allocator,
        "test-1",
        "Test Agent",
        "A test agent",
        config,
        TestProcessor.process,
    );
    defer agent.destroy(allocator);

    try std.testing.expect(!agent.isActive());
    try agent.load();
    try std.testing.expect(agent.isActive());

    const result = try agent.process(allocator, "Hello", null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
    try std.testing.expectEqual(@as(u64, 1), agent.info.use_count);
}
