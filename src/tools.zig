//! Tool system: registry and bash executor via std.process.Child
const std = @import("std");
const http = std.http;

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8, // JSON Schema string
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    exit_code: u8,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDefinition),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDefinition).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn get(self: *ToolRegistry, name: []const u8) ?ToolDefinition {
        return self.tools.get(name);
    }

    /// Serialize all registered tools into the OpenAI function-calling JSON format
    pub fn toOpenAIToolsJson(self: *ToolRegistry, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("[", .{});
        var first = true;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (!first) try w.print(",", .{});
            first = false;
            const t = entry.value_ptr.*;
            try w.print(
                \\{{"type":"function","function":{{"name":"{s}","description":{f},"parameters":{s}}}}}
            , .{ t.name, std.json.fmt(t.description, .{}), t.parameters_schema });
        }
        try w.print("]", .{});

        return try allocator.dupe(u8, buf.items);
    }

    /// Serialize tools into Anthropic tool format
    pub fn toAnthropicToolsJson(self: *ToolRegistry, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("[", .{});
        var first = true;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (!first) try w.print(",", .{});
            first = false;
            const t = entry.value_ptr.*;
            try w.print(
                \\{{"name":"{s}","description":{f},"input_schema":{s}}}
            , .{ t.name, std.json.fmt(t.description, .{}), t.parameters_schema });
        }
        try w.print("]", .{});

        return try allocator.dupe(u8, buf.items);
    }
};

// ── Bash Tool ─────────────────────────────────────────────────────

pub const BashTool = struct {
    const MAX_OUTPUT: usize = 512 * 1024; // 512KB

    pub const SCHEMA =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"}},"required":["command"]}
    ;

    pub fn definition() ToolDefinition {
        return .{
            .name = "bash",
            .description = "Execute a bash command and return stdout/stderr. Use this for all system operations: running code, git, file manipulation, installing packages, etc.",
            .parameters_schema = SCHEMA,
        };
    }

    /// Execute a bash command and capture output
    pub fn execute(allocator: std.mem.Allocator, command: []const u8, cwd: ?[]const u8) !ToolResult {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/bin/bash", "-c", command },
            .cwd = cwd,
            .max_output_bytes = MAX_OUTPUT,
        });

        // Combine stdout and stderr
        var output: []u8 = undefined;
        if (result.stderr.len > 0 and result.stdout.len > 0) {
            output = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ result.stdout, result.stderr });
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        } else if (result.stderr.len > 0) {
            output = result.stderr;
            allocator.free(result.stdout);
        } else {
            output = result.stdout;
            allocator.free(result.stderr);
        }

        const exit_code: u8 = switch (result.term) {
            .Exited => |code| code,
            .Signal => 128,
            .Stopped => 127,
            .Unknown => 126,
        };

        return .{
            .success = exit_code == 0,
            .output = output,
            .exit_code = exit_code,
        };
    }
};

// ── HTTP Fetch Tool ───────────────────────────────────────────────

pub const FetchTool = struct {
    const MAX_RESPONSE_SIZE: usize = 50 * 1024; // 50KB limit for LLM context
    const REQUEST_TIMEOUT_MS: usize = 30000; // 30 seconds

    pub const SCHEMA =
        \\{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch"},"method":{"type":"string","enum":["GET","POST"],"description":"HTTP method"},"headers":{"type":"object","description":"Optional custom headers as key-value pairs"},"body":{"type":"string","description":"Optional request body for POST requests"}},"required":["url","method"]}
    ;

    pub fn definition() ToolDefinition {
        return .{
            .name = "fetch",
            .description = "Fetch a URL using HTTP GET or POST. Returns the response body and status code. Supports custom headers and request body.",
            .parameters_schema = SCHEMA,
        };
    }

    pub const FetchOptions = struct {
        url: []const u8,
        method: []const u8,
        headers: ?std.json.ObjectMap = null,
        body: ?[]const u8 = null,
    };

    pub const FetchResponse = struct {
        status: u16,
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *FetchResponse) void {
            self.allocator.free(self.body);
        }
    };

    /// Parse JSON arguments and execute fetch
    pub fn executeFromJson(allocator: std.mem.Allocator, json_args: []const u8) !ToolResult {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_args, .{});
        defer parsed.deinit();

        const root = parsed.value;

        // Get required fields
        const url = root.object.get("url") orelse return error.MissingUrl;
        const method = root.object.get("method") orelse return error.MissingMethod;

        // Get optional fields
        const headers = root.object.get("headers");
        const body = root.object.get("body");

        const opts = FetchOptions{
            .url = url.string,
            .method = method.string,
            .headers = if (headers) |h| h.object else null,
            .body = if (body) |b| b.string else null,
        };

        return execute(allocator, opts);
    }

    /// Execute HTTP request
    pub fn execute(allocator: std.mem.Allocator, opts: FetchOptions) !ToolResult {
        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        // Parse URL
        const uri = try std.Uri.parse(opts.url);

        // Set method
        const method = std.meta.stringToEnum(http.Method, opts.method) orelse {
            const error_msg = try std.fmt.allocPrint(allocator, "Invalid HTTP method: {s}", .{opts.method});
            return ToolResult{
                .success = false,
                .output = error_msg,
                .exit_code = 1,
            };
        };

        // Build headers
        var headers = http.Headers{ .allocator = allocator };
        defer headers.deinit();

        // Add default headers
        try headers.append("User-Agent", "Mozilla/5.0 (compatible; ZigBot/1.0)");

        // Add custom headers if provided
        if (opts.headers) |custom_headers| {
            var it = custom_headers.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                try headers.append(key, value.string);
            }
        }

        // Add Content-Type for POST with body
        if (method == .POST and opts.body != null) {
            var has_content_type = false;
            if (opts.headers) |custom_headers| {
                has_content_type = custom_headers.contains("Content-Type");
            }
            if (!has_content_type) {
                try headers.append("Content-Type", "application/x-www-form-urlencoded");
            }
        }

        // Allocate response buffer
        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        // Prepare body
        const body_bytes: ?[]const u8 = opts.body;

        // Make the request
        const response = client.fetch(.{
            .method = method,
            .uri = uri,
            .headers = headers,
            .payload = body_bytes,
            .response_storage = .{ .dynamic = &response_buffer },
        }) catch |err| {
            const error_msg = try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)});
            return ToolResult{
                .success = false,
                .output = error_msg,
                .exit_code = 1,
            };
        };

        // Truncate if too large for LLM context
        const response_body = response_buffer.items;
        var output: []const u8 = undefined;

        if (response_body.len > MAX_RESPONSE_SIZE) {
            output = try std.fmt.allocPrint(allocator, "Status: {d}\n\n{s}\n\n... (truncated, {d} bytes total)", .{
                response.status,
                response_body[0..MAX_RESPONSE_SIZE],
                response_body.len,
            });
        } else {
            output = try std.fmt.allocPrint(allocator, "Status: {d}\n\n{s}", .{
                response.status,
                response_body,
            });
        }

        const is_success = response.status >= 200 and response.status < 300;
        const exit_code: u8 = if (is_success) 0 else @as(u8, @intCast(@min(response.status, 255)));

        return ToolResult{
            .success = is_success,
            .output = output,
            .exit_code = exit_code,
        };
    }
};

test "bash tool definition" {
    const def = BashTool.definition();
    try std.testing.expectEqualStrings("bash", def.name);
}

test "tool registry" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(BashTool.definition());
    const tool = registry.get("bash");
    try std.testing.expect(tool != null);
    try std.testing.expectEqualStrings("bash", tool.?.name);
}

test "bash tool executes echo" {
    const allocator = std.testing.allocator;
    const result = try BashTool.execute(allocator, "echo hello", null);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.exit_code == 0);
    try std.testing.expectEqualStrings("hello\n", result.output);
}

test "bash tool captures exit code" {
    const allocator = std.testing.allocator;
    const result = try BashTool.execute(allocator, "exit 42", null);
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code == 42);
}

test "openai tools json" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(BashTool.definition());
    const json = try registry.toOpenAIToolsJson(allocator);
    defer allocator.free(json);

    // Should contain the function definition
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"function\"") != null);
}

// ── Fetch Tool Tests ──────────────────────────────────────────────

test "fetch tool definition" {
    const def = FetchTool.definition();
    try std.testing.expectEqualStrings("fetch", def.name);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_schema, "\"url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_schema, "\"method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_schema, "\"headers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.parameters_schema, "\"body\"") != null);
}

test "fetch tool registered in registry" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(BashTool.definition());
    try registry.register(FetchTool.definition());

    const bash_tool = registry.get("bash");
    const fetch_tool = registry.get("fetch");

    try std.testing.expect(bash_tool != null);
    try std.testing.expect(fetch_tool != null);
    try std.testing.expectEqualStrings("bash", bash_tool.?.name);
    try std.testing.expectEqualStrings("fetch", fetch_tool.?.name);
}

test "fetch tool executes GET request to httpbin" {
    const allocator = std.testing.allocator;

    const opts = FetchTool.FetchOptions{
        .url = "https://httpbin.org/get",
        .method = "GET",
        .headers = null,
        .body = null,
    };

    const result = try FetchTool.execute(allocator, opts);
    defer result.deinit(allocator);

    // httpbin returns 200 for GET requests
    // Note: This test requires network access and may fail in offline environments
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Status: 200") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"url\"") != null or
            std.mem.indexOf(u8, result.output, "httpbin") != null);
    }
}

test "fetch tool handles invalid URL" {
    const allocator = std.testing.allocator;

    const opts = FetchTool.FetchOptions{
        .url = "not-a-valid-url",
        .method = "GET",
        .headers = null,
        .body = null,
    };

    const result = try FetchTool.execute(allocator, opts);
    defer result.deinit(allocator);

    // Should fail but not crash
    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code != 0);
}

test "fetch tool with custom headers" {
    const allocator = std.testing.allocator;

    // Build headers map
    var headers = std.json.ObjectMap.init(allocator);
    defer headers.deinit();

    const accept_value = std.json.Value{ .string = "application/json" };
    try headers.put("Accept", accept_value);

    const opts = FetchTool.FetchOptions{
        .url = "https://httpbin.org/headers",
        .method = "GET",
        .headers = headers,
        .body = null,
    };

    const result = try FetchTool.execute(allocator, opts);
    defer result.deinit(allocator);

    // Should succeed if we have network access
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Status: 200") != null);
    }
}

test "fetch tool parses JSON arguments" {
    const allocator = std.testing.allocator;

    const json_args =
        \\{"url": "https://httpbin.org/get", "method": "GET"}
    ;

    const result = try FetchTool.executeFromJson(allocator, json_args);
    defer result.deinit(allocator);

    // Should either succeed or fail gracefully
    // We check that it parses and executes without crashing
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Status:") != null);
    }
}

test "registry includes fetch in OpenAI JSON" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(BashTool.definition());
    try registry.register(FetchTool.definition());

    const json = try registry.toOpenAIToolsJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fetch\"") != null);
}

test "registry includes fetch in Anthropic JSON" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(BashTool.definition());
    try registry.register(FetchTool.definition());

    const json = try registry.toAnthropicToolsJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fetch\"") != null);
}
