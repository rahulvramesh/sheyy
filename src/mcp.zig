//! MCP (Model Context Protocol) client - STDIO transport
//! Spawns MCP servers as subprocesses, communicates via newline-delimited JSON-RPC 2.0
const std = @import("std");
const tools_mod = @import("tools.zig");

pub const McpError = error{
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    ParseError,
    ProtocolError,
    Timeout,
    ServerDead,
    OutOfMemory,
};

/// A single MCP server connection
pub const McpClient = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    child: std.process.Child,
    next_id: u64,
    // Tools discovered from this server
    tools: std.ArrayList(McpTool),
    is_initialized: bool,

    pub const McpTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema: []const u8, // raw JSON schema string
    };

    /// Spawn an MCP server process and initialize the connection
    pub fn connect(
        allocator: std.mem.Allocator,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        env_map: ?*const std.process.EnvMap,
    ) !*McpClient {
        const client = try allocator.create(McpClient);
        errdefer allocator.destroy(client);

        // Build argv: command + args (must be owned, outlive this scope)
        const argv = blk: {
            var argv_list: std.ArrayList([]const u8) = .empty;
            errdefer argv_list.deinit(allocator);
            try argv_list.append(allocator, command);
            for (args) |arg| {
                try argv_list.append(allocator, arg);
            }
            break :blk try argv_list.toOwnedSlice(allocator);
        };

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.env_map = env_map;

        client.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .child = child,
            .next_id = 1,
            .tools = .empty,
            .is_initialized = false,
        };
        // argv is now owned by client.child (as .argv field)

        client.child.spawn() catch |err| {
            std.log.err("Failed to spawn MCP server '{s}': {s}", .{ name, @errorName(err) });
            allocator.free(client.name);
            allocator.destroy(client);
            return McpError.SpawnFailed;
        };

        std.log.info("MCP server '{s}' spawned (pid)", .{name});

        // Initialize handshake
        client.initialize() catch |err| {
            std.log.err("MCP init failed for '{s}': {s}", .{ name, @errorName(err) });
            client.shutdown();
            allocator.free(client.name);
            allocator.destroy(client);
            return err;
        };

        // Discover tools
        client.discoverTools() catch |err| {
            std.log.err("MCP tool discovery failed for '{s}': {s}", .{ name, @errorName(err) });
            // Continue anyway, server is alive but has no tools
        };
        _ = &client;

        return client;
    }

    pub fn deinit(self: *McpClient) void {
        self.shutdown();
        for (self.tools.items) |tool| {
            self.allocator.free(tool.name);
            self.allocator.free(tool.description);
            self.allocator.free(tool.input_schema);
        }
        self.tools.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    fn shutdown(self: *McpClient) void {
        // Close stdin to signal the server to exit
        if (self.child.stdin) |*stdin| {
            stdin.close();
            self.child.stdin = null;
        }
        if (self.child.stdout) |*stdout| {
            stdout.close();
            self.child.stdout = null;
        }
        if (self.child.stderr) |*stderr| {
            stderr.close();
            self.child.stderr = null;
        }
        _ = self.child.wait() catch {};
    }

    /// Send JSON-RPC initialize request
    fn initialize(self: *McpClient) !void {
        const init_req = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"protocolVersion":"2024-11-05","capabilities":{{"sampling":{{}}}},"clientInfo":{{"name":"my_zig_agent","version":"1.0.0"}}}}}}
        , .{self.nextId()});
        defer self.allocator.free(init_req);

        try self.sendMessage(init_req);
        const response = try self.readMessage();
        defer self.allocator.free(response);

        // Check for error in response
        if (std.mem.indexOf(u8, response, "\"error\"") != null and
            std.mem.indexOf(u8, response, "\"result\"") == null)
        {
            std.log.err("MCP init error from '{s}': {s}", .{ self.name, response });
            return McpError.ProtocolError;
        }

        std.log.info("MCP '{s}' initialized", .{self.name});
        self.is_initialized = true;

        // Send initialized notification (no id, no response expected)
        const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
        try self.sendMessage(notif);
    }

    /// Discover tools from the MCP server
    fn discoverTools(self: *McpClient) !void {
        const req = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/list","params":{{}}}}
        , .{self.nextId()});
        defer self.allocator.free(req);

        try self.sendMessage(req);
        const response = try self.readMessage();
        defer self.allocator.free(response);

        // Parse the tools from the response
        try self.parseToolsResponse(response);

        std.log.info("MCP '{s}' discovered {d} tools", .{ self.name, self.tools.items.len });
    }

    fn parseToolsResponse(self: *McpClient, response: []const u8) !void {
        // We need to parse: {"jsonrpc":"2.0","id":N,"result":{"tools":[{name,description,inputSchema}]}}
        // Use std.json to parse the full response
        const parsed = std.json.parseFromSlice(
            struct {
                result: ?struct {
                    tools: ?[]const struct {
                        name: []const u8,
                        description: ?[]const u8 = null,
                        inputSchema: ?std.json.Value = null,
                    } = null,
                } = null,
            },
            self.allocator,
            response,
            .{ .ignore_unknown_fields = true },
        ) catch {
            std.log.err("MCP '{s}' tools parse failed: {s}", .{ self.name, response });
            return;
        };
        defer parsed.deinit();

        const result = parsed.value.result orelse return;
        const tool_list = result.tools orelse return;

        for (tool_list) |tool| {
            // Serialize inputSchema back to JSON string
            const schema_str = if (tool.inputSchema) |schema|
                std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(schema, .{})}) catch continue
            else
                self.allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}") catch continue;

            try self.tools.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, tool.name),
                .description = try self.allocator.dupe(u8, tool.description orelse ""),
                .input_schema = schema_str,
            });

            std.log.info("  MCP tool: {s}", .{tool.name});
        }
    }

    /// Call a tool on this MCP server
    pub fn callTool(self: *McpClient, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        if (!self.is_initialized) return McpError.ProtocolError;

        const req = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
        , .{ self.nextId(), tool_name, arguments_json });
        defer self.allocator.free(req);

        try self.sendMessage(req);
        const response = try self.readMessage();
        defer self.allocator.free(response);

        // Parse result content
        return self.parseToolCallResponse(response);
    }

    fn parseToolCallResponse(self: *McpClient, response: []const u8) ![]u8 {
        // Response format: {"jsonrpc":"2.0","id":N,"result":{"content":[{"type":"text","text":"..."}]}}
        // or error: {"jsonrpc":"2.0","id":N,"error":{"code":N,"message":"..."}}
        const ContentBlock = struct {
            type: ?[]const u8 = null,
            text: ?[]const u8 = null,
        };
        const ResultData = struct {
            content: ?[]const ContentBlock = null,
            isError: ?bool = null,
        };
        const ErrorData = struct {
            code: ?i64 = null,
            message: ?[]const u8 = null,
        };
        const Resp = struct {
            result: ?ResultData = null,
            @"error": ?ErrorData = null,
        };

        const parsed = std.json.parseFromSlice(Resp, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch {
            return try self.allocator.dupe(u8, "MCP: Failed to parse tool response");
        };
        defer parsed.deinit();

        // Check for error
        if (parsed.value.@"error") |err| {
            return try std.fmt.allocPrint(self.allocator, "MCP Error: {s}", .{err.message orelse "unknown error"});
        }

        // Extract text content
        if (parsed.value.result) |result| {
            if (result.content) |blocks| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                const w = buf.writer(self.allocator);

                for (blocks) |block| {
                    const block_type = block.type orelse "text";
                    if (std.mem.eql(u8, block_type, "text")) {
                        if (block.text) |text| {
                            try w.print("{s}", .{text});
                        }
                    }
                }

                if (buf.items.len > 0) {
                    return try self.allocator.dupe(u8, buf.items);
                }
            }
        }

        return try self.allocator.dupe(u8, "MCP: Empty response");
    }

    // ── I/O Helpers ───────────────────────────────────────────────

    fn sendMessage(self: *McpClient, message: []const u8) !void {
        var stdin = self.child.stdin orelse return McpError.WriteFailed;
        stdin.writeAll(message) catch return McpError.WriteFailed;
        stdin.writeAll("\n") catch return McpError.WriteFailed;
    }

    fn readMessage(self: *McpClient) ![]u8 {
        const stdout = self.child.stdout orelse return McpError.ReadFailed;
        // Read one line (newline-delimited JSON-RPC) byte by byte
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const max_size: usize = 2 * 1024 * 1024;
        while (buf.items.len < max_size) {
            var byte: [1]u8 = undefined;
            const n = stdout.read(&byte) catch |err| {
                std.log.err("MCP '{s}' read error: {s}", .{ self.name, @errorName(err) });
                return McpError.ReadFailed;
            };
            if (n == 0) {
                // EOF - process likely died
                return McpError.ServerDead;
            }
            if (byte[0] == '\n') break;
            try buf.append(self.allocator, byte[0]);
        }

        if (buf.items.len == 0) return McpError.ReadFailed;

        return try self.allocator.dupe(u8, buf.items);
    }

    fn nextId(self: *McpClient) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

// ── MCP Manager ───────────────────────────────────────────────────

/// Manages multiple MCP server connections and routes tool calls
pub const McpManager = struct {
    allocator: std.mem.Allocator,
    clients: std.StringHashMap(*McpClient),
    // Maps tool_name -> server_name for routing
    tool_routes: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) McpManager {
        return .{
            .allocator = allocator,
            .clients = std.StringHashMap(*McpClient).init(allocator),
            .tool_routes = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *McpManager) void {
        // Free route values (duped server names)
        var route_it = self.tool_routes.iterator();
        while (route_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tool_routes.deinit();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.clients.deinit();
    }

    /// Add an MCP server connection
    pub fn addServer(self: *McpManager, client: *McpClient) !void {
        try self.clients.put(client.name, client);

        // Register tool routes
        for (client.tools.items) |tool| {
            const key = try self.allocator.dupe(u8, tool.name);
            const val = try self.allocator.dupe(u8, client.name);
            try self.tool_routes.put(key, val);
        }
    }

    /// Register all MCP tools into a ToolRegistry
    pub fn registerToolsInRegistry(self: *McpManager, registry: *tools_mod.ToolRegistry) !void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            for (client.tools.items) |tool| {
                try registry.register(.{
                    .name = tool.name,
                    .description = tool.description,
                    .parameters_schema = tool.input_schema,
                });
            }
        }
    }

    /// Check if a tool belongs to an MCP server
    pub fn isToolMcp(self: *McpManager, tool_name: []const u8) bool {
        return self.tool_routes.contains(tool_name);
    }

    /// Execute a tool call via the appropriate MCP server
    pub fn callTool(self: *McpManager, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        const server_name = self.tool_routes.get(tool_name) orelse return error.ToolNotFound;
        const client = self.clients.get(server_name) orelse return error.ServerNotFound;
        return client.callTool(tool_name, arguments_json);
    }

    /// Get count of all MCP tools across all servers
    pub fn toolCount(self: *McpManager) usize {
        var count: usize = 0;
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            count += entry.value_ptr.*.tools.items.len;
        }
        return count;
    }
};

// ── Config Loading ────────────────────────────────────────────────

/// JSON shape for mcp_servers.json
const McpServerConfig = struct {
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?std.json.ObjectMap = null,
};

/// Load MCP server configs and connect to all of them
pub fn loadMcpServers(
    allocator: std.mem.Allocator,
    config_path: []const u8,
) !McpManager {
    var manager = McpManager.init(allocator);
    errdefer manager.deinit();

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
        std.log.info("No MCP config at {s}: {s}", .{ config_path, @errorName(err) });
        return manager;
    };
    defer allocator.free(content);

    // Parse as a map of server_name -> config
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    ) catch |err| {
        std.log.err("Failed to parse MCP config: {s}", .{@errorName(err)});
        return manager;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.log.err("MCP config must be a JSON object", .{});
            return manager;
        },
    };

    var it = root.iterator();
    while (it.next()) |entry| {
        const server_name = entry.key_ptr.*;
        const server_val = entry.value_ptr.*;

        const obj = switch (server_val) {
            .object => |o| o,
            else => continue,
        };

        const command = blk: {
            const val = obj.get("command") orelse continue;
            break :blk switch (val) {
                .string => |s| s,
                else => continue,
            };
        };

        // Parse args array
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(allocator);
        if (obj.get("args")) |args_val| {
            switch (args_val) {
                .array => |arr| {
                    for (arr.items) |item| {
                        switch (item) {
                            .string => |s| try args_list.append(allocator, s),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Parse env map
        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();

        // Inherit current process environment
        var sys_env = std.process.getEnvMap(allocator) catch {
            @as(void, {});
            break;
        };
        defer sys_env.deinit();
        {
            var sys_it = sys_env.iterator();
            while (sys_it.next()) |e| {
                env_map.put(e.key_ptr.*, e.value_ptr.*) catch {};
            }
        }

        // Add config-specified env vars
        if (obj.get("env")) |env_val| {
            switch (env_val) {
                .object => |env_obj| {
                    var env_it = env_obj.iterator();
                    while (env_it.next()) |e| {
                        switch (e.value_ptr.*) {
                            .string => |s| env_map.put(e.key_ptr.*, s) catch {},
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        std.log.info("Connecting to MCP server: {s} ({s})", .{ server_name, command });

        const client = McpClient.connect(
            allocator,
            server_name,
            command,
            args_list.items,
            &env_map,
        ) catch |err| {
            std.log.err("MCP server '{s}' failed: {s}", .{ server_name, @errorName(err) });
            continue;
        };

        manager.addServer(client) catch |err| {
            std.log.err("Failed to register MCP server '{s}': {s}", .{ server_name, @errorName(err) });
            client.deinit();
            continue;
        };

        std.log.info("MCP server '{s}' connected with {d} tools", .{ server_name, client.tools.items.len });
    }

    return manager;
}
