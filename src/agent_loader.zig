//! Agent Loader - Loads agent definitions from files
const std = @import("std");
const agent = @import("agent.zig");
const Agent = agent.Agent;
const AgentConfig = agent.AgentConfig;
const AgentError = agent.AgentError;
const AgentType = agent.AgentType;
const llm = @import("llm.zig");

/// Agent definition file format
pub const AgentDefinition = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    version: []const u8 = "1.0.0",
    author: ?[]const u8 = null,
    agent_type: []const u8 = "built_in",
    enabled: bool = true,
    config: AgentConfigDefinition,
};

/// Configuration section of agent definition
const AgentConfigDefinition = struct {
    model_id: []const u8,
    system_prompt: ?[]const u8 = null,
    temperature: f32 = 0.7,
    max_tokens: i32 = 4096,
};

/// Context data stored in agent's custom_data field
const AgentContext = struct {
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,
};

/// Agent Loader - Loads and creates agents from definition files
pub const AgentLoader = struct {
    allocator: std.mem.Allocator,
    llm_client: *llm.LlmClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llm_client: *llm.LlmClient) Self {
        return Self{
            .allocator = allocator,
            .llm_client = llm_client,
        };
    }

    /// Load an agent from a JSON definition file
    pub fn loadFromFile(self: *Self, file_path: []const u8) AgentError!*Agent {
        // Read the file
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch |err| {
            std.log.err("Failed to read agent definition file {s}: {s}", .{ file_path, @errorName(err) });
            return AgentError.LoadFailed;
        };
        defer self.allocator.free(content);

        // Parse the JSON
        const definition = std.json.parseFromSlice(AgentDefinition, self.allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse agent definition {s}: {s}", .{ file_path, @errorName(err) });
            return AgentError.ConfigError;
        };
        defer definition.deinit();

        // Create the agent
        return try self.createAgentFromDefinition(&definition.value);
    }

    /// Create an agent from a definition struct
    fn createAgentFromDefinition(
        self: *Self,
        def: *const AgentDefinition,
    ) AgentError!*Agent {
        // Create the configuration
        const config = AgentConfig{
            .name = def.config.model_id,
            .description = def.name,
            .model_id = def.config.model_id,
            .system_prompt = def.config.system_prompt,
            .temperature = def.config.temperature,
            .max_tokens = def.config.max_tokens,
            .enabled = def.enabled,
        };

        // Create context data for the agent
        const context = self.allocator.create(AgentContext) catch {
            return AgentError.OutOfMemory;
        };
        context.* = .{
            .allocator = self.allocator,
            .llm_client = self.llm_client,
        };

        // Create the agent with LLM processor
        const agent_ptr = Agent.createBuiltIn(
            self.allocator,
            def.id,
            def.name,
            def.description,
            config,
            llmProcessor,
        ) catch |err| {
            std.log.err("Failed to create agent: {s}", .{@errorName(err)});
            return AgentError.LoadFailed;
        };

        // Store context in agent's custom_data
        agent_ptr.custom_data = context;

        return agent_ptr;
    }

    /// Load all agents from a directory
    pub fn loadAllFromDirectory(
        self: *Self,
        dir_path: []const u8,
        registry: anytype,
    ) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.log.warn("Failed to open agents directory {s}: {s}", .{ dir_path, @errorName(err) });
            return;
        };
        defer dir.close();

        var count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Only process .json files
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const full_path = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;
            defer self.allocator.free(full_path);

            // Load the agent
            const agent_ptr = self.loadFromFile(full_path) catch |err| {
                std.log.err("Failed to load agent from {s}: {s}", .{ entry.name, @errorName(err) });
                continue;
            };

            // Register with the registry
            registry.registerAgent(agent_ptr, full_path) catch |err| {
                std.log.err("Failed to register agent {s}: {s}", .{ agent_ptr.info.id, @errorName(err) });
                // Free the context
                if (agent_ptr.custom_data) |ctx| {
                    self.allocator.destroy(@as(*AgentContext, @ptrCast(@alignCast(ctx))));
                }
                agent_ptr.destroy(self.allocator);
                continue;
            };

            count += 1;
        }

        std.log.info("Loaded {d} agents from {s}", .{ count, dir_path });
    }

    /// Create a built-in agent programmatically
    pub fn createBuiltInAgent(
        self: *Self,
        id: []const u8,
        name: []const u8,
        description: []const u8,
        model_id: []const u8,
        system_prompt: ?[]const u8,
    ) AgentError!*Agent {
        const config = AgentConfig{
            .name = model_id,
            .description = name,
            .model_id = model_id,
            .system_prompt = system_prompt,
        };

        // Create context data
        const context = self.allocator.create(AgentContext) catch {
            return AgentError.OutOfMemory;
        };
        context.* = .{
            .allocator = self.allocator,
            .llm_client = self.llm_client,
        };

        const agent_ptr = Agent.createBuiltIn(
            self.allocator,
            id,
            name,
            description,
            config,
            llmProcessor,
        ) catch |err| {
            self.allocator.destroy(context);
            std.log.err("Failed to create built-in agent: {s}", .{@errorName(err)});
            return AgentError.LoadFailed;
        };

        // Store context
        agent_ptr.custom_data = context;

        return agent_ptr;
    }

    /// LLM processor that actually calls the LLM
    fn llmProcessor(ag: *Agent, alloc: std.mem.Allocator, msg: []const u8, ctx: ?*anyopaque) AgentError![]u8 {
        _ = alloc;
        _ = ctx;

        // Get context from agent
        const agent_ctx = @as(*AgentContext, @ptrCast(@alignCast(ag.custom_data.?)));
        const llm_client = agent_ctx.llm_client;

        // For now, just call the LLM directly
        // In a more advanced implementation, we could prepend the system prompt
        // or modify the request based on agent configuration
        const response = llm_client.chatCompletion(msg) catch |err| {
            std.log.err("LLM call failed: {s}", .{@errorName(err)});
            return AgentError.ProcessFailed;
        };

        // The response is owned by the caller (allocator), so we can return it directly
        // But we need to ensure it's properly freed by the caller
        return response;
    }

    /// Save an agent definition to file
    pub fn saveToFile(
        self: *Self,
        agent_ptr: *Agent,
        file_path: []const u8,
    ) !void {
        const definition = AgentDefinition{
            .id = agent_ptr.info.id,
            .name = agent_ptr.info.name,
            .description = agent_ptr.info.description,
            .version = agent_ptr.info.version,
            .author = agent_ptr.info.author,
            .agent_type = switch (agent_ptr.info.agent_type) {
                .built_in => "built_in",
                .dynamic => "dynamic",
                .remote => "remote",
            },
            .enabled = agent_ptr.info.config.enabled,
            .config = .{
                .model_id = agent_ptr.info.config.model_id,
                .system_prompt = agent_ptr.info.config.system_prompt,
                .temperature = agent_ptr.info.config.temperature,
                .max_tokens = agent_ptr.info.config.max_tokens,
            },
        };

        const json = std.json.stringifyAlloc(self.allocator, definition, .{
            .whitespace = .indent_2,
        }) catch |err| {
            std.log.err("Failed to serialize agent definition: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(json);

        std.fs.cwd().writeFile(.{
            .sub_path = file_path,
            .data = json,
        }) catch |err| {
            std.log.err("Failed to write agent definition to {s}: {s}", .{ file_path, @errorName(err) });
        };
    }
};

test "AgentLoader basic test" {
    // This test would require a real LLM client
    // For unit testing, we skip the full integration test
    try std.testing.expect(true);
}
