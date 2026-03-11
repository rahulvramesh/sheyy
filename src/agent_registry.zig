//! Agent Registry - Manages multiple agents with hot reload support
const std = @import("std");
const agent = @import("agent.zig");
const Agent = agent.Agent;
const AgentInfo = agent.AgentInfo;
const AgentError = agent.AgentError;
const AgentEvent = agent.AgentEvent;
const AgentConfig = agent.AgentConfig;

/// Agent entry in the registry
const AgentEntry = struct {
    agent: *Agent,
    source_path: ?[]const u8, // For hot reload tracking
    last_modified: ?i128, // File modification time
};

/// Agent Registry - Manages a collection of agents
pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.StringHashMap(AgentEntry),
    active_agent_id: ?[]const u8,
    agents_dir: []const u8,
    event_handler: ?agent.AgentEventHandler,
    auto_reload: bool,
    reload_interval_ms: u32,

    const Self = @This();

    /// Initialize the agent registry
    pub fn init(
        allocator: std.mem.Allocator,
        agents_dir: []const u8,
        auto_reload: bool,
    ) !Self {
        return Self{
            .allocator = allocator,
            .agents = std.StringHashMap(AgentEntry).init(allocator),
            .active_agent_id = null,
            .agents_dir = try allocator.dupe(u8, agents_dir),
            .event_handler = null,
            .auto_reload = auto_reload,
            .reload_interval_ms = 5000, // 5 seconds
        };
    }

    /// Deinitialize the registry and all agents
    pub fn deinit(self: *Self) void {
        // Unload and destroy all agents
        var it = self.agents.iterator();
        while (it.next()) |entry| {
            const agent_entry = entry.value_ptr;
            agent_entry.agent.unload() catch {};
            agent_entry.agent.destroy(self.allocator);
            if (agent_entry.source_path) |path| {
                self.allocator.free(path);
            }
        }
        self.agents.deinit();

        if (self.active_agent_id) |id| {
            self.allocator.free(id);
        }
        self.allocator.free(self.agents_dir);
    }

    /// Register an agent in the registry
    pub fn registerAgent(
        self: *Self,
        agent_ptr: *Agent,
        source_path: ?[]const u8,
    ) AgentError!void {
        // Check if agent already exists
        if (self.agents.contains(agent_ptr.info.id)) {
            return AgentError.AgentAlreadyExists;
        }

        // Copy source path if provided
        const path_copy: ?[]const u8 = if (source_path) |path|
            try self.allocator.dupe(u8, path)
        else
            null;

        // Get file modification time if source path exists
        const last_mod: ?i128 = if (path_copy) |path|
            self.getFileModTime(path) catch null
        else
            null;

        const entry = AgentEntry{
            .agent = agent_ptr,
            .source_path = path_copy,
            .last_modified = last_mod,
        };

        try self.agents.put(agent_ptr.info.id, entry);

        // Load the agent
        try agent_ptr.load();

        // Notify event handler
        if (self.event_handler) |handler| {
            handler(AgentEvent.loaded, agent_ptr.info.id, null);
        }

        std.log.info("Registered agent: {s} ({s})", .{ agent_ptr.info.name, agent_ptr.info.id });
    }

    /// Unregister an agent
    pub fn unregisterAgent(self: *Self, agent_id: []const u8) AgentError!void {
        const entry = self.agents.getEntry(agent_id) orelse {
            return AgentError.AgentNotFound;
        };

        const agent_entry = entry.value_ptr;

        // Unload the agent
        try agent_entry.agent.unload();

        // Notify event handler
        if (self.event_handler) |handler| {
            handler(AgentEvent.unloaded, agent_id, null);
        }

        // Clean up
        agent_entry.agent.destroy(self.allocator);
        if (agent_entry.source_path) |path| {
            self.allocator.free(path);
        }

        _ = self.agents.remove(agent_id);

        // Clear active agent if this was the active one
        if (self.active_agent_id) |active_id| {
            if (std.mem.eql(u8, active_id, agent_id)) {
                self.allocator.free(active_id);
                self.active_agent_id = null;
            }
        }

        std.log.info("Unregistered agent: {s}", .{agent_id});
    }

    /// Get an agent by ID
    pub fn getAgent(self: *Self, agent_id: []const u8) ?*Agent {
        const entry = self.agents.get(agent_id) orelse return null;
        return entry.agent;
    }

    /// Set the active agent
    pub fn setActiveAgent(self: *Self, agent_id: []const u8) AgentError!void {
        if (!self.agents.contains(agent_id)) {
            return AgentError.AgentNotFound;
        }

        // Free old active agent ID
        if (self.active_agent_id) |old_id| {
            self.allocator.free(old_id);
        }

        // Set new active agent
        self.active_agent_id = try self.allocator.dupe(u8, agent_id);

        std.log.info("Active agent set to: {s}", .{agent_id});
    }

    /// Get the active agent
    pub fn getActiveAgent(self: *Self) ?*Agent {
        const id = self.active_agent_id orelse return null;
        return self.getAgent(id);
    }

    /// Get active agent info
    pub fn getActiveAgentInfo(self: *Self) ?AgentInfo {
        const agent_ptr = self.getActiveAgent() orelse return null;
        return agent_ptr.info;
    }

    /// List all registered agents
    pub fn listAgents(self: *Self, allocator: std.mem.Allocator) ![]AgentInfo {
        var list = std.ArrayList(AgentInfo).init(allocator);
        errdefer list.deinit();

        var it = self.agents.iterator();
        while (it.next()) |entry| {
            try list.append(entry.value_ptr.agent.info);
        }

        return list.toOwnedSlice();
    }

    /// Check if an agent is the active one
    pub fn isActiveAgent(self: *Self, agent_id: []const u8) bool {
        const active = self.active_agent_id orelse return false;
        return std.mem.eql(u8, active, agent_id);
    }

    /// Reload an agent
    pub fn reloadAgent(self: *Self, agent_id: []const u8) AgentError!void {
        const entry = self.agents.getEntry(agent_id) orelse {
            return AgentError.AgentNotFound;
        };

        const agent_entry = entry.value_ptr;

        std.log.info("Reloading agent: {s}", .{agent_id});

        // Reload the agent
        try agent_entry.agent.reload();

        // Update modification time
        if (agent_entry.source_path) |path| {
            agent_entry.last_modified = self.getFileModTime(path) catch null;
        }

        // Notify event handler
        if (self.event_handler) |handler| {
            handler(AgentEvent.reloaded, agent_id, null);
        }

        std.log.info("Agent reloaded successfully: {s}", .{agent_id});
    }

    /// Check for changes and hot reload agents
    pub fn checkAndReload(self: *Self) void {
        if (!self.auto_reload) return;

        var it = self.agents.iterator();
        while (it.next()) |entry| {
            const agent_entry = entry.value_ptr;

            // Skip if no source path
            const source_path = agent_entry.source_path orelse continue;

            // Check if file has been modified
            const current_mod = self.getFileModTime(source_path) catch continue;
            const last_mod = agent_entry.last_modified orelse current_mod;

            if (current_mod > last_mod) {
                std.log.info("Detected change in agent: {s}", .{entry.key_ptr.*});
                self.reloadAgent(entry.key_ptr.*) catch |err| {
                    std.log.err("Failed to reload agent {s}: {s}", .{
                        entry.key_ptr.*,
                        @errorName(err),
                    });
                };
            }
        }
    }

    /// Get file modification time
    fn getFileModTime(_: *Self, path: []const u8) !i128 {
        const stat = try std.fs.cwd().statFile(path);
        return stat.mtime;
    }

    /// Set event handler
    pub fn setEventHandler(self: *Self, handler: agent.AgentEventHandler) void {
        self.event_handler = handler;
    }

    /// Get count of registered agents
    pub fn agentCount(self: *Self) usize {
        return self.agents.count();
    }

    /// Process a message with the active agent
    pub fn processWithActive(
        self: *Self,
        message: []const u8,
        context: ?*anyopaque,
    ) AgentError![]u8 {
        const active_agent = self.getActiveAgent() orelse {
            return AgentError.AgentNotFound;
        };

        if (!active_agent.isActive()) {
            return AgentError.AgentNotActive;
        }

        return try active_agent.process(self.allocator, message, context);
    }
};

/// Default agent processor that uses LLM
pub fn createDefaultAgentProcessor(
    allocator: std.mem.Allocator,
    _: anytype,
) !*Agent {
    const config = AgentConfig{
        .name = "Default Assistant",
        .description = "General purpose AI assistant",
        .model_id = "kimi-k2.5",
        .system_prompt = "You are a helpful AI assistant.",
    };

    const DefaultProcessor = struct {
        fn process(ag: *Agent, alloc: std.mem.Allocator, msg: []const u8, ctx: ?*anyopaque) AgentError![]u8 {
            _ = ag;
            _ = ctx;

            // For now, just return the message (in real implementation, would call LLM)
            return alloc.dupe(u8, msg) catch return AgentError.OutOfMemory;
        }
    };

    return try Agent.createBuiltIn(
        allocator,
        "default",
        "Default Assistant",
        "General purpose AI assistant",
        config,
        DefaultProcessor.process,
    );
}

test "AgentRegistry basic operations" {
    const allocator = std.testing.allocator;

    var registry = try AgentRegistry.init(allocator, "./agents", false);
    defer registry.deinit();

    // Create a test agent
    const config = AgentConfig{
        .name = "Test Agent",
        .description = "Test",
        .model_id = "test",
    };

    const TestProcessor = struct {
        fn process(ag: *Agent, alloc: std.mem.Allocator, msg: []const u8, ctx: ?*anyopaque) AgentError![]u8 {
            _ = ag;
            _ = ctx;
            return alloc.dupe(u8, msg) catch return AgentError.OutOfMemory;
        }
    };

    const test_agent = try Agent.createBuiltIn(
        allocator,
        "test-1",
        "Test Agent",
        "Test",
        config,
        TestProcessor.process,
    );

    // Register the agent
    try registry.registerAgent(test_agent, null);
    try std.testing.expectEqual(@as(usize, 1), registry.agentCount());

    // Get the agent
    const retrieved = registry.getAgent("test-1");
    try std.testing.expect(retrieved != null);

    // Set as active
    try registry.setActiveAgent("test-1");
    try std.testing.expect(registry.isActiveAgent("test-1"));

    // Unregister
    try registry.unregisterAgent("test-1");
    try std.testing.expectEqual(@as(usize, 0), registry.agentCount());
}
