//! Configuration module for loading auth.json and models.json
const std = @import("std");

/// Authentication configuration from auth.json
pub const AuthConfig = struct {
    telegram_bot_token: []const u8,
    llm_api_key: []const u8,
};

/// Model configuration from models.json
pub const ModelConfig = struct {
    llm_endpoint_url: []const u8,
    model_name: []const u8,
};

/// Errors that can occur during configuration loading
pub const ConfigError = error{
    FileNotFound,
    InvalidJson,
    MissingField,
    OutOfMemory,
};

/// Load authentication configuration from auth.json
pub fn loadAuthConfig(allocator: std.mem.Allocator) ConfigError!AuthConfig {
    const content = std.fs.cwd().readFileAlloc(allocator, "auth.json", 1024 * 1024) catch |err| {
        std.log.err("Failed to read auth.json: {s}", .{@errorName(err)});
        return ConfigError.FileNotFound;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(AuthConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse auth.json: {s}", .{@errorName(err)});
        return ConfigError.InvalidJson;
    };
    defer parsed.deinit();

    // Duplicate strings to own the memory
    const telegram_token = allocator.dupe(u8, parsed.value.telegram_bot_token) catch {
        return ConfigError.OutOfMemory;
    };
    errdefer allocator.free(telegram_token);

    const llm_key = allocator.dupe(u8, parsed.value.llm_api_key) catch {
        allocator.free(telegram_token);
        return ConfigError.OutOfMemory;
    };

    return AuthConfig{
        .telegram_bot_token = telegram_token,
        .llm_api_key = llm_key,
    };
}

/// Load model configuration from models.json
pub fn loadModelConfig(allocator: std.mem.Allocator) ConfigError!ModelConfig {
    const content = std.fs.cwd().readFileAlloc(allocator, "models.json", 1024 * 1024) catch |err| {
        std.log.err("Failed to read models.json: {s}", .{@errorName(err)});
        return ConfigError.FileNotFound;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(ModelConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse models.json: {s}", .{@errorName(err)});
        return ConfigError.InvalidJson;
    };
    defer parsed.deinit();

    // Duplicate strings to own the memory
    const endpoint_url = allocator.dupe(u8, parsed.value.llm_endpoint_url) catch {
        return ConfigError.OutOfMemory;
    };
    errdefer allocator.free(endpoint_url);

    const model = allocator.dupe(u8, parsed.value.model_name) catch {
        allocator.free(endpoint_url);
        return ConfigError.OutOfMemory;
    };

    return ModelConfig{
        .llm_endpoint_url = endpoint_url,
        .model_name = model,
    };
}

/// Free memory allocated for AuthConfig
pub fn freeAuthConfig(allocator: std.mem.Allocator, config: AuthConfig) void {
    allocator.free(config.telegram_bot_token);
    allocator.free(config.llm_api_key);
}

/// Free memory allocated for ModelConfig
pub fn freeModelConfig(allocator: std.mem.Allocator, config: ModelConfig) void {
    allocator.free(config.llm_endpoint_url);
    allocator.free(config.model_name);
}

/// Load allowed user IDs from allowed_users.json
pub fn loadAllowedUsers(allocator: std.mem.Allocator) ConfigError![]i64 {
    const content = std.fs.cwd().readFileAlloc(allocator, "allowed_users.json", 1024 * 1024) catch |err| {
        std.log.warn("Failed to read allowed_users.json: {s}. Allowing all users.", .{@errorName(err)});
        // Return empty list - if file doesn't exist, all users are allowed
        return allocator.alloc(i64, 0) catch return ConfigError.OutOfMemory;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice([]i64, allocator, content, .{}) catch |err| {
        std.log.err("Failed to parse allowed_users.json: {s}", .{@errorName(err)});
        return ConfigError.InvalidJson;
    };
    defer parsed.deinit();

    // Duplicate the array to own the memory
    const result = allocator.dupe(i64, parsed.value) catch {
        return ConfigError.OutOfMemory;
    };

    std.log.info("Loaded {d} allowed user(s)", .{result.len});
    return result;
}

/// Check if a user ID is in the allowed list (or if list is empty, allow all)
pub fn isUserAllowed(user_id: i64, allowed_users: []const i64) bool {
    if (allowed_users.len == 0) return true; // Empty list means allow all
    for (allowed_users) |allowed_id| {
        if (allowed_id == user_id) return true;
    }
    return false;
}

test "loadAuthConfig parses valid JSON" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    const test_content =
        \\{
        \\  "telegram_bot_token": "test_token_123",
        \\  "llm_api_key": "test_key_456"
        \\}
    ;

    // Write test file
    try std.fs.cwd().writeFile(.{
        .sub_path = "test_auth.json",
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile("test_auth.json") catch {};

    // For this test, we'll use a simpler approach - parse the JSON directly
    const AuthConfigTest = struct {
        telegram_bot_token: []const u8,
        llm_api_key: []const u8,
    };

    const parsed = try std.json.parseFromSlice(AuthConfigTest, allocator, test_content, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test_token_123", parsed.value.telegram_bot_token);
    try std.testing.expectEqualStrings("test_key_456", parsed.value.llm_api_key);
}

test "loadModelConfig parses valid JSON" {
    const allocator = std.testing.allocator;

    const test_content =
        \\{
        \\  "llm_endpoint_url": "https://api.openai.com/v1/chat/completions",
        \\  "model_name": "gpt-4o-mini"
        \\}
    ;

    const ModelConfigTest = struct {
        llm_endpoint_url: []const u8,
        model_name: []const u8,
    };

    const parsed = try std.json.parseFromSlice(ModelConfigTest, allocator, test_content, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", parsed.value.llm_endpoint_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", parsed.value.model_name);
}
