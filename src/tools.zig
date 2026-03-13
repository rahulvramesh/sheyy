//! Tool system: registry and bash executor via std.process.Child
const std = @import("std");

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
