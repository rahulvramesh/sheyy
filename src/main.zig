//! Personal AI Assistant Bot - Multi-Agent Orchestration System
const std = @import("std");
const config = @import("config.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const conversation = @import("conversation.zig");
const agent_mod = @import("agent.zig");
const team_mod = @import("team.zig");
const orchestrator_mod = @import("orchestrator.zig");
const mcp = @import("mcp.zig");
const memory_cortex = @import("memory_cortex.zig");
const router = @import("router.zig");

// ── Per-Chat State ────────────────────────────────────────────────

const ChatMode = enum {
    super_agent, // autonomous routing (default)
    direct_agent, // chatting with a single agent (manual override)
    team_task, // orchestrator managing a team task
};

const ChatState = struct {
    mode: ChatMode,
    active_agent_id: ?[]const u8,
    active_team_id: ?[]const u8,

    fn deinit(self: *ChatState, allocator: std.mem.Allocator) void {
        if (self.active_agent_id) |id| allocator.free(id);
        if (self.active_team_id) |id| allocator.free(id);
    }
};

// ── File Manager ──────────────────────────────────────────────────

const FileMetadata = struct {
    path: []const u8,
    original_name: ?[]const u8,
    mime_type: ?[]const u8,
    size: i64,
    timestamp: i64,
    chat_id: i64,

    fn deinit(self: FileMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.original_name) |n| allocator.free(n);
        if (self.mime_type) |m| allocator.free(m);
    }
};

const FileManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    max_files: usize,

    const Self = @This();
    const CleanupFile = struct { name: []const u8, mtime: i128 };

    fn init(allocator: std.mem.Allocator, base_dir: []const u8) !Self {
        // Ensure files directory exists
        const files_dir = try std.fs.path.join(allocator, &.{ base_dir, "files" });
        defer allocator.free(files_dir);
        try std.fs.cwd().makePath(files_dir);

        return Self{
            .allocator = allocator,
            .base_dir = try allocator.dupe(u8, base_dir),
            .max_files = 100,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.base_dir);
    }

    fn getChatFilesDir(self: *Self, chat_id: i64) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/files/{d}", .{ self.base_dir, chat_id });
    }

    fn generateUniqueFilename(self: *Self, _chat_id: i64, original_name: ?[]const u8) ![]const u8 {
        _ = _chat_id;
        const timestamp = std.time.timestamp();
        const random = std.crypto.random.int(u32);

        if (original_name) |name| {
            const ext = std.fs.path.extension(name);
            const basename = std.fs.path.stem(name);
            return std.fmt.allocPrint(self.allocator, "{d}_{d}_{s}{s}", .{ timestamp, random, basename, ext });
        } else {
            return std.fmt.allocPrint(self.allocator, "{d}_{d}_file", .{ timestamp, random });
        }
    }

    fn saveFile(self: *Self, chat_id: i64, data: []const u8, original_name: ?[]const u8, mime_type: ?[]const u8) !FileMetadata {
        const chat_dir = try self.getChatFilesDir(chat_id);
        defer self.allocator.free(chat_dir);
        try std.fs.cwd().makePath(chat_dir);

        const filename = try self.generateUniqueFilename(chat_id, original_name);
        defer self.allocator.free(filename);

        const filepath = try std.fs.path.join(self.allocator, &.{ chat_dir, filename });
        errdefer self.allocator.free(filepath);

        // Write file
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        try file.writeAll(data);

        // Clean up old files
        try self.cleanupOldFiles(chat_id);

        return FileMetadata{
            .path = filepath,
            .original_name = if (original_name) |n| try self.allocator.dupe(u8, n) else null,
            .mime_type = if (mime_type) |m| try self.allocator.dupe(u8, m) else null,
            .size = @intCast(data.len),
            .timestamp = std.time.timestamp(),
            .chat_id = chat_id,
        };
    }

    fn cleanupOldFiles(self: *Self, chat_id: i64) !void {
        const chat_dir = try self.getChatFilesDir(chat_id);
        defer self.allocator.free(chat_dir);

        var dir = std.fs.cwd().openDir(chat_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var files: std.ArrayList(CleanupFile) = .empty;
        defer {
            for (files.items) |f| self.allocator.free(f.name);
            files.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const stat = dir.statFile(entry.name) catch continue;
            try files.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.name),
                .mtime = stat.mtime,
            });
        }

        if (files.items.len <= self.max_files) return;

        // Sort by modification time (oldest first)
        const SortContext = struct {};
        std.mem.sort(CleanupFile, files.items, SortContext{}, struct {
            fn lessThan(_: SortContext, a: CleanupFile, b: CleanupFile) bool {
                return a.mtime < b.mtime;
            }
        }.lessThan);

        // Delete oldest files
        const to_delete = files.items.len - self.max_files;
        for (files.items[0..to_delete]) |file| {
            const filepath = try std.fs.path.join(self.allocator, &.{ chat_dir, file.name });
            defer self.allocator.free(filepath);
            std.fs.cwd().deleteFile(filepath) catch {};
        }
    }

    fn listRecentFiles(self: *Self, chat_id: i64, _limit: usize) ![]FileMetadata {
        _ = _limit;
        const chat_dir = try self.getChatFilesDir(chat_id);
        defer self.allocator.free(chat_dir);

        var dir = std.fs.cwd().openDir(chat_dir, .{ .iterate = true }) catch return &[_]FileMetadata{};
        defer dir.close();

        var files: std.ArrayList(FileMetadata) = .empty;
        errdefer {
            for (files.items) |f| f.deinit(self.allocator);
            files.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const filepath = try std.fs.path.join(self.allocator, &.{ chat_dir, entry.name });
            const stat = std.fs.cwd().statFile(filepath) catch continue;

            try files.append(self.allocator, .{
                .path = filepath,
                .original_name = null,
                .mime_type = null,
                .size = @intCast(stat.size),
                .timestamp = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
                .chat_id = chat_id,
            });
        }

        // Sort by timestamp (newest first)
        const MetadataSortContext = struct {};
        std.mem.sort(FileMetadata, files.items, MetadataSortContext{}, struct {
            fn lessThan(_: MetadataSortContext, a: FileMetadata, b: FileMetadata) bool {
                return a.timestamp > b.timestamp;
            }
        }.lessThan);

        const result = try files.toOwnedSlice(self.allocator);
        return result;
    }

    fn getFileContext(self: *Self, chat_id: i64, allocator: std.mem.Allocator) ![]const u8 {
        const files = try self.listRecentFiles(chat_id, 10);
        defer {
            for (files) |f| f.deinit(self.allocator);
            self.allocator.free(files);
        }

        if (files.len == 0) return allocator.dupe(u8, "");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("\n\nAvailable files in workspace:\n", .{});
        for (files) |file| {
            const basename = std.fs.path.basename(file.path);
            try w.print("  - {s} ({d} bytes)\n", .{ basename, file.size });
        }
        try w.print("\nYou can reference these files in your responses or use bash to work with them.", .{});

        return try allocator.dupe(u8, buf.items);
    }
};

// ── Application State ─────────────────────────────────────────────

const AppState = struct {
    allocator: std.mem.Allocator,
    tg: *telegram.TelegramClient,
    llm_client: *llm.LlmClient,
    agents: std.StringHashMap(*agent_mod.AgentDef),
    teams: std.StringHashMap(*team_mod.TeamDef),
    tool_registry: *tools_mod.ToolRegistry,
    runtime: *agent_mod.AgentRuntime,
    orchestrator: *orchestrator_mod.Orchestrator,
    chat_states: std.AutoHashMap(i64, ChatState),
    conversations: std.AutoHashMap(i64, conversation.Conversation),
    cortex: *memory_cortex.MemoryCortex,
    super_agent: *router.SuperAgent,
    file_manager: FileManager,
    work_dir: []const u8, // base working directory
    persist_dir: []const u8, // memory persistence dir
    max_history: usize,
    max_context: usize,
    last_reload_check: i64,

    fn getActiveAgent(self: *AppState, chat_id: i64) ?*agent_mod.AgentDef {
        const cs = self.chat_states.get(chat_id) orelse return null;
        const id = cs.active_agent_id orelse return null;
        return self.agents.get(id);
    }

    fn setActiveAgent(self: *AppState, chat_id: i64, agent_id: []const u8) !void {
        if (!self.agents.contains(agent_id)) return error.AgentNotFound;
        const result = try self.chat_states.getOrPut(chat_id);
        if (result.found_existing) {
            if (result.value_ptr.active_agent_id) |old| self.allocator.free(old);
        } else {
            result.value_ptr.* = .{ .mode = .super_agent, .active_agent_id = null, .active_team_id = null };
        }
        result.value_ptr.active_agent_id = try self.allocator.dupe(u8, agent_id);
        result.value_ptr.mode = .direct_agent;
    }

    fn getOrCreateConv(self: *AppState, chat_id: i64) !*conversation.Conversation {
        const result = try self.conversations.getOrPut(chat_id);
        if (!result.found_existing) {
            if (conversation.loadConversation(self.allocator, self.persist_dir, chat_id)) |loaded| {
                result.value_ptr.* = loaded;
            } else {
                result.value_ptr.* = conversation.Conversation.init();
            }
        }
        return result.value_ptr;
    }

    fn getChatState(self: *AppState, chat_id: i64) !*ChatState {
        const result = try self.chat_states.getOrPut(chat_id);
        if (!result.found_existing) {
            result.value_ptr.* = .{ .mode = .super_agent, .active_agent_id = null, .active_team_id = null };
        }
        return result.value_ptr;
    }
};

// ── File Handling ─────────────────────────────────────────────────

fn handleFileMessage(state: *AppState, msg: telegram.Message) !?FileMetadata {
    if (!msg.has_file) return null;

    var file_info: ?telegram.FileInfo = null;
    var original_name: ?[]const u8 = null;
    var mime_type: ?[]const u8 = null;

    // Handle photos - use largest photo
    if (msg.photos) |photos| {
        if (photos.len > 0) {
            const photo = photos[0];
            // Check file size limit
            if (photo.file_size) |size| {
                if (size > 20 * 1024 * 1024) {
                    std.log.err("Photo file too large: {d} bytes", .{size});
                    return null;
                }
            }
            file_info = try state.tg.getFile(photo.file_id);
            original_name = try std.fmt.allocPrint(state.allocator, "photo_{d}x{d}.jpg", .{ photo.width, photo.height });
            mime_type = "image/jpeg";
        }
    }
    // Handle documents
    else if (msg.document) |doc| {
        // Check file size limit
        if (doc.file_size) |size| {
            if (size > 50 * 1024 * 1024) {
                std.log.err("Document file too large: {d} bytes", .{size});
                return null;
            }
        }
        file_info = try state.tg.getFile(doc.file_id);

        // Extract filename from file_path if available
        if (file_info.?.file_path) |path| {
            original_name = try state.allocator.dupe(u8, std.fs.path.basename(path));
        }
    }

    if (file_info == null or file_info.?.file_path == null) {
        if (original_name) |n| state.allocator.free(n);
        return null;
    }

    // Download the file
    const file_data = try state.tg.downloadFile(file_info.?.file_path.?);
    defer state.allocator.free(file_data);

    // Save to workspace
    const metadata = try state.file_manager.saveFile(msg.chat_id, file_data, original_name, mime_type);

    // Cleanup
    file_info.?.deinit(state.allocator);
    if (original_name) |n| state.allocator.free(n);

    return metadata;
}

fn buildMessageWithContext(state: *AppState, chat_id: i64, text: ?[]const u8, file_metadata: ?FileMetadata) ![]const u8 {
    // Build message context with proper memory management
    // Track which strings need to be freed
    var allocated_strings: std.ArrayList([]const u8) = .empty;
    defer allocated_strings.deinit(state.allocator);
    defer {
        for (allocated_strings.items) |s| {
            state.allocator.free(s);
        }
    }

    var total_len: usize = 0;

    // Add text content
    if (text) |t| {
        total_len += t.len;
    }

    // Add file information
    var file_info: ?[]const u8 = null;
    if (file_metadata) |meta| {
        if (text != null) total_len += 2; // "\n\n"

        file_info = try std.fmt.allocPrint(state.allocator, "[File received: {s} ({d} bytes)]\nSaved to: {s}", .{ meta.original_name orelse "unnamed", meta.size, meta.path });
        try allocated_strings.append(state.allocator, file_info.?);
        total_len += file_info.?.len;
    }

    // Add available files context
    const file_context = try state.file_manager.getFileContext(chat_id, state.allocator);
    defer state.allocator.free(file_context);
    const has_file_context = file_context.len > 0;
    if (has_file_context) {
        total_len += file_context.len;
    }

    // Allocate result
    var result = try state.allocator.alloc(u8, total_len);
    var offset: usize = 0;

    // Copy text
    if (text) |t| {
        @memcpy(result[offset .. offset + t.len], t);
        offset += t.len;
    }

    // Copy separator and file info
    if (file_metadata != null) {
        if (text != null) {
            @memcpy(result[offset .. offset + 2], "\n\n");
            offset += 2;
        }
        if (file_info) |info| {
            @memcpy(result[offset .. offset + info.len], info);
            offset += info.len;
        }
    }

    // Copy file context
    if (has_file_context) {
        @memcpy(result[offset .. offset + file_context.len], file_context);
        offset += file_context.len;
    }

    return result;
}

// ── Message Processing ────────────────────────────────────────────

fn processMessage(state: *AppState, chat_id: i64, text: []const u8, file_metadata: ?FileMetadata) void {
    // Build message with file context
    const message_with_context = buildMessageWithContext(state, chat_id, text, file_metadata) catch |err| blk: {
        std.log.err("Failed to build message context: {s}", .{@errorName(err)});
        break :blk text;
    };
    defer if (message_with_context.ptr != text.ptr) state.allocator.free(message_with_context);

    const cs = state.chat_states.get(chat_id);
    const mode: ChatMode = if (cs) |s| s.mode else .super_agent;

    switch (mode) {
        .team_task => {
            // Check if orchestrator session is still active
            if (state.orchestrator.getSession(chat_id)) |session| {
                if (session.state == .done or session.state == .failed) {
                    // Task finished, clean up and fall through to super agent
                    state.orchestrator.cancelTask(chat_id);
                    const cs_ptr = state.getChatState(chat_id) catch return;
                    cs_ptr.mode = .super_agent;
                    // Fall through to super_agent below
                } else {
                    state.orchestrator.handleMessage(session, message_with_context) catch |err| {
                        std.log.err("Orchestrator error: {s}", .{@errorName(err)});
                        state.tg.sendMessage(chat_id, "Error processing task.") catch {};
                    };
                    return;
                }
            } else {
                // No session but mode is team_task - reset
                const cs_ptr = state.getChatState(chat_id) catch return;
                cs_ptr.mode = .super_agent;
            }
            // Fall through to super agent
            processViaSuperAgent(state, chat_id, message_with_context);
        },
        .super_agent => {
            processViaSuperAgent(state, chat_id, message_with_context);
        },
        .direct_agent => {
            processViaDirectAgent(state, chat_id, message_with_context);
        },
    }
}

fn processViaSuperAgent(state: *AppState, chat_id: i64, text: []const u8) void {
    const result = state.super_agent.handleMessage(chat_id, text);
    switch (result) {
        .stay => {},
        .team_task => {
            // Super agent decided to start a team task
            const cs = state.getChatState(chat_id) catch return;
            cs.mode = .team_task;
        },
    }
}

fn processViaDirectAgent(state: *AppState, chat_id: i64, text: []const u8) void {
    state.tg.sendTyping(chat_id) catch {};

    const agent_def = state.getActiveAgent(chat_id) orelse {
        state.tg.sendMessage(chat_id, "No active agent. Use /agents or /auto.") catch {};
        return;
    };

    const conv = state.getOrCreateConv(chat_id) catch {
        state.tg.sendMessage(chat_id, "Memory error.") catch {};
        return;
    };

    conv.addMessage(state.allocator, "user", text) catch return;
    conv.trim(state.allocator, state.max_history);

    if (agent_def.tool_names.len > 0) {
        const progress_id = state.tg.sendMessageReturningId(chat_id, "Thinking...") catch 0;
        const progress = if (progress_id != 0) progress_id else null;

        const response = state.runtime.run(
            agent_def,
            conv,
            chat_id,
            progress,
            null,
        ) catch |err| {
            std.log.err("Agent runtime error: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Sorry, something went wrong. Please try again.") catch {};
            return;
        };
        defer state.allocator.free(response);

        conv.addMessage(state.allocator, "assistant", response) catch {};
        conversation.saveConversation(state.allocator, state.persist_dir, chat_id, conv);

        if (progress) |pid| {
            if (response.len <= 4096) {
                state.tg.editMessage(chat_id, pid, response) catch {
                    state.tg.sendMessage(chat_id, response) catch {};
                };
            } else {
                state.tg.editMessage(chat_id, pid, "Done! See response below:") catch {};
                state.tg.sendMessage(chat_id, response) catch {};
            }
        } else {
            state.tg.sendMessage(chat_id, response) catch {};
        }
    } else {
        const items = conv.messages.items;
        const start = if (items.len > state.max_context) items.len - state.max_context else 0;
        const context_msgs = items[start..];

        const final_messages = state.allocator.alloc(llm.ChatMessage, 1 + context_msgs.len) catch return;
        defer state.allocator.free(final_messages);

        final_messages[0] = .{ .role = "system", .content = agent_def.system_prompt };
        for (context_msgs, 1..) |msg, i| {
            final_messages[i] = .{ .role = msg.role, .content = msg.content orelse "" };
        }

        const response = state.llm_client.chatCompletion(
            final_messages,
            agent_def.model_id,
            agent_def.temperature,
            agent_def.api_format,
        ) catch |err| {
            std.log.err("LLM error: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Sorry, the AI service returned an error. Please try again.") catch {};
            return;
        };
        defer state.allocator.free(response);

        conv.addMessage(state.allocator, "assistant", response) catch {};
        conversation.saveConversation(state.allocator, state.persist_dir, chat_id, conv);

        state.tg.sendMessage(chat_id, response) catch |err| {
            std.log.err("Send failed: {s}", .{@errorName(err)});
        };
    }
}

// ── Command Handling ──────────────────────────────────────────────

fn isCommand(text: []const u8) bool {
    return text.len > 1 and text[0] == '/';
}

fn parseCommand(text: []const u8) struct { cmd: []const u8, args: []const u8 } {
    const start: usize = if (text[0] == '/') 1 else 0;
    var end = start;
    while (end < text.len and text[end] != ' ') end += 1;
    const args_start = if (end < text.len) end + 1 else text.len;
    return .{
        .cmd = text[start..end],
        .args = if (args_start < text.len) text[args_start..] else "",
    };
}

fn handleCommand(state: *AppState, chat_id: i64, text: []const u8) void {
    const parsed = parseCommand(text);
    const cmd = parsed.cmd;
    const args = parsed.args;

    if (std.mem.eql(u8, cmd, "start") or std.mem.eql(u8, cmd, "help")) {
        state.tg.sendMessage(chat_id,
            \\AI Agent Bot (Auto-routing enabled)
            \\
            \\Just send a message - I'll automatically choose the right agent or team!
            \\You can also send photos and documents.
            \\
            \\Manual Override:
            \\/agent <id> - Switch to a specific agent
            \\/auto - Re-enable auto-routing
            \\/agents - List available agents
            \\
            \\Team Commands:
            \\/teams - List available teams
            \\/team <id> <task> - Start a team task manually
            \\/task - Show current task status
            \\/cancel - Cancel current task
            \\
            \\File Commands:
            \\/files - List available files in workspace
            \\/sendfile <path> - Send a file back to chat
            \\
            \\Memory:
            \\/memory add <text> - Store a memory
            \\/memory search <query> - Search memories
            \\/memory stats - Show memory stats
            \\/memory clear - Clear all memories
            \\/memory delete <id> - Delete a memory
            \\
            \\General:
            \\/clear - Clear conversation
            \\/history - Show recent messages
            \\/reload - Reload configs from disk
            \\/help - Show this message
        ) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "agents")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Available Agents:\n\n", .{}) catch return;

        var it = state.agents.iterator();
        while (it.next()) |entry| {
            const ag = entry.value_ptr.*;
            const cs = state.chat_states.get(chat_id);
            const active = if (cs) |s| (if (s.active_agent_id) |aid| std.mem.eql(u8, aid, ag.id) else false) else false;
            const icon: []const u8 = if (active) ">" else " ";
            const tool_info: []const u8 = if (ag.tool_names.len > 0) " [has tools]" else "";
            w.print("{s} {s} - {s}{s}\n", .{ icon, ag.name, ag.description, tool_info }) catch continue;
        }
        w.print("\nUse /agent <id> to switch", .{}) catch {};
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "agent")) {
        if (args.len == 0) {
            if (state.getActiveAgent(chat_id)) |ag| {
                const tool_info = if (ag.tool_names.len > 0) " (with tools)" else "";
                const msg = std.fmt.allocPrint(state.allocator, "Active agent: {s} ({s})\nModel: {s}{s}", .{ ag.name, ag.id, ag.model_id, tool_info }) catch return;
                defer state.allocator.free(msg);
                state.tg.sendMessage(chat_id, msg) catch {};
            } else {
                state.tg.sendMessage(chat_id, "No active agent.") catch {};
            }
            return;
        }

        if (state.agents.contains(args)) {
            state.setActiveAgent(chat_id, args) catch return;
            if (state.conversations.getPtr(chat_id)) |conv| {
                conv.clear(state.allocator);
            }
            const msg = std.fmt.allocPrint(state.allocator, "Switched to: {s}. Conversation cleared.", .{args}) catch return;
            defer state.allocator.free(msg);
            state.tg.sendMessage(chat_id, msg) catch {};
        } else {
            state.tg.sendMessage(chat_id, "Agent not found. Use /agents to see available agents.") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "teams")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Available Teams:\n\n", .{}) catch return;

        if (state.teams.count() == 0) {
            w.print("No teams configured. Add team JSON files to the teams/ directory.", .{}) catch {};
        } else {
            var it = state.teams.iterator();
            while (it.next()) |entry| {
                const tm = entry.value_ptr.*;
                w.print("  {s} - {s} ({d} roles)\n", .{ tm.id, tm.description, tm.roles.len }) catch continue;
            }
            w.print("\nUse /team <id> <task description> to start a team task", .{}) catch {};
        }
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "team")) {
        if (args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /team <team_id> <task description>") catch {};
            return;
        }

        // Parse: first word is team_id, rest is the task
        var split_iter = std.mem.splitScalar(u8, args, ' ');
        const team_id = split_iter.next() orelse {
            state.tg.sendMessage(chat_id, "Usage: /team <team_id> <task description>") catch {};
            return;
        };

        const team_def = state.teams.get(team_id) orelse {
            const msg = std.fmt.allocPrint(state.allocator, "Team '{s}' not found. Use /teams to see available teams.", .{team_id}) catch return;
            defer state.allocator.free(msg);
            state.tg.sendMessage(chat_id, msg) catch {};
            return;
        };

        const task_desc = split_iter.rest();
        if (task_desc.len == 0) {
            state.tg.sendMessage(chat_id, "Please provide a task description: /team <id> <what you want done>") catch {};
            return;
        }

        // Set chat mode to team
        const cs = state.getChatState(chat_id) catch return;
        cs.mode = .team_task;
        if (cs.active_team_id) |old| state.allocator.free(old);
        cs.active_team_id = state.allocator.dupe(u8, team_id) catch return;

        // Start the orchestrator
        state.orchestrator.startTask(chat_id, team_def, task_desc) catch |err| {
            std.log.err("Failed to start task: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Failed to start task.") catch {};
        };
        return;
    }

    if (std.mem.eql(u8, cmd, "task")) {
        if (state.orchestrator.getSession(chat_id)) |session| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(state.allocator);
            const w = buf.writer(state.allocator);

            w.print("Task Status: {s}\n", .{@tagName(session.state)}) catch return;
            w.print("Team: {s}\n\n", .{session.team.name}) catch {};

            if (session.subtasks.items.len > 0) {
                w.print("Subtasks:\n", .{}) catch {};
                for (session.subtasks.items) |subtask| {
                    const icon: []const u8 = switch (subtask.state) {
                        .pending => "[ ]",
                        .in_progress => "[..]",
                        .completed => "[ok]",
                        .failed => "[!!]",
                    };
                    w.print("  {s} {s}\n", .{ icon, subtask.title }) catch continue;
                }
            }
            state.tg.sendMessage(chat_id, buf.items) catch {};
        } else {
            state.tg.sendMessage(chat_id, "No active task. Use /team <id> <description> to start one.") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "auto")) {
        const cs = state.getChatState(chat_id) catch return;
        cs.mode = .super_agent;
        if (cs.active_agent_id) |old| state.allocator.free(old);
        cs.active_agent_id = null;
        state.tg.sendMessage(chat_id, "Auto-routing enabled. I'll decide the best agent for each task.") catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "cancel")) {
        state.orchestrator.cancelTask(chat_id);
        const cs = state.getChatState(chat_id) catch return;
        cs.mode = .super_agent;
        return;
    }

    if (std.mem.eql(u8, cmd, "clear")) {
        if (state.conversations.getPtr(chat_id)) |conv| {
            conv.clear(state.allocator);
        }
        const filename = std.fmt.allocPrint(state.allocator, "{s}/chat_{d}.json", .{ state.persist_dir, chat_id }) catch return;
        defer state.allocator.free(filename);
        std.fs.cwd().deleteFile(filename) catch {};

        state.tg.sendMessage(chat_id, "Conversation cleared.") catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "history")) {
        const conv = state.conversations.get(chat_id) orelse {
            state.tg.sendMessage(chat_id, "No conversation history.") catch {};
            return;
        };

        if (conv.messages.items.len == 0) {
            state.tg.sendMessage(chat_id, "No conversation history.") catch {};
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Recent conversation ({d} messages):\n\n", .{conv.messages.items.len}) catch return;
        const items = conv.messages.items;
        const start = if (items.len > 10) items.len - 10 else 0;
        for (items[start..]) |msg| {
            if (std.mem.eql(u8, msg.role, "tool")) continue; // skip tool messages in history view
            const label: []const u8 = if (std.mem.eql(u8, msg.role, "user")) "You" else "AI";
            const content = msg.content orelse "(tool call)";
            const preview = if (content.len > 200) content[0..200] else content;
            w.print("{s}: {s}", .{ label, preview }) catch continue;
            if (content.len > 200) w.print("...", .{}) catch {};
            w.print("\n\n", .{}) catch {};
        }
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "reload")) {
        agent_mod.reloadAgents(state.allocator, &state.agents);
        team_mod.reloadTeams(state.allocator, &state.teams, "teams");
        state.tg.sendMessage(chat_id, "Configs reloaded.") catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "files")) {
        const files = state.file_manager.listRecentFiles(chat_id, 20) catch |err| {
            std.log.err("Failed to list files: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Error listing files.") catch {};
            return;
        };
        defer {
            for (files) |f| f.deinit(state.allocator);
            state.allocator.free(files);
        }

        if (files.len == 0) {
            state.tg.sendMessage(chat_id, "No files in workspace. Send me photos or documents!") catch {};
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Files in workspace ({d} total):\n\n", .{files.len}) catch return;
        for (files) |file| {
            const basename = std.fs.path.basename(file.path);
            const size_kb = @divFloor(file.size, 1024);
            w.print("  - {s} ({d} KB)\n", .{ basename, size_kb }) catch continue;
        }
        w.print("\nUse /sendfile <filename> to send a file.", .{}) catch {};
        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "sendfile")) {
        if (args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /sendfile <filename>\nUse /files to see available files.") catch {};
            return;
        }

        // Try to find the file
        var file_path: ?[]const u8 = null;
        defer if (file_path) |p| state.allocator.free(p);

        // First, check if it's a full path
        if (std.fs.path.isAbsolute(args)) {
            file_path = state.allocator.dupe(u8, args) catch |err| {
                std.log.err("Error duplicating path: {s}", .{@errorName(err)});
                state.tg.sendMessage(chat_id, "Error processing file path.") catch {};
                return;
            };
        } else {
            // Try to find in chat files directory
            const chat_dir = state.file_manager.getChatFilesDir(chat_id) catch |err| {
                std.log.err("Error getting chat dir: {s}", .{@errorName(err)});
                state.tg.sendMessage(chat_id, "File not found.") catch {};
                return;
            };
            defer state.allocator.free(chat_dir);
            const full_path = std.fs.path.join(state.allocator, &.{ chat_dir, args }) catch |err| {
                std.log.err("Error creating path: {s}", .{@errorName(err)});
                state.tg.sendMessage(chat_id, "File not found.") catch {};
                return;
            };

            // Check if file exists directly
            const file_exists = blk: {
                std.fs.cwd().access(full_path, .{}) catch break :blk false;
                break :blk true;
            };

            if (file_exists) {
                file_path = full_path;
            } else {
                state.allocator.free(full_path);
                // Try without subdirectories
                var dir = std.fs.cwd().openDir(chat_dir, .{ .iterate = true }) catch {
                    state.tg.sendMessage(chat_id, "File not found.") catch {};
                    return;
                };
                defer dir.close();

                var found = false;
                var it = dir.iterate();
                while (it.next() catch |err| {
                    std.log.err("Error iterating directory: {s}", .{@errorName(err)});
                    return;
                }) |entry| {
                    if (entry.kind != .file) continue;
                    if (std.mem.eql(u8, entry.name, args) or std.mem.endsWith(u8, entry.name, args)) {
                        file_path = std.fs.path.join(state.allocator, &.{ chat_dir, entry.name }) catch |err| {
                            std.log.err("Error creating path: {s}", .{@errorName(err)});
                            return;
                        };
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    state.tg.sendMessage(chat_id, "File not found. Use /files to see available files.") catch {};
                    return;
                }
            }
        }

        // Send the file
        state.tg.sendDocument(chat_id, file_path.?, null) catch |err| {
            std.log.err("Failed to send file: {s}", .{@errorName(err)});
            state.tg.sendMessage(chat_id, "Failed to send file. Check that the file exists and is under 50MB.") catch {};
            return;
        };
        return;
    }

    if (std.mem.eql(u8, cmd, "memory")) {
        handleMemoryCommand(state, chat_id, args);
        return;
    }

    state.tg.sendMessage(chat_id, "Unknown command. Use /help.") catch {};
}

// ── Memory Command ────────────────────────────────────────────────

fn handleMemoryCommand(state: *AppState, chat_id: i64, args: []const u8) void {
    if (args.len == 0) {
        state.tg.sendMessage(chat_id,
            \\Usage:
            \\/memory add <text> - Store a memory (use #tags)
            \\/memory search <query> - Search memories
            \\/memory stats - Show memory statistics
            \\/memory clear - Clear all memories
            \\/memory delete <id> - Delete a memory by ID
        ) catch {};
        return;
    }

    // Parse subcommand
    var split_iter = std.mem.splitScalar(u8, args, ' ');
    const subcmd = split_iter.next() orelse "";
    const sub_args = split_iter.rest();

    if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory add <text to remember>") catch {};
            return;
        }
        state.cortex.add(sub_args, "user", &.{}) catch {
            state.tg.sendMessage(chat_id, "Failed to save memory.") catch {};
            return;
        };
        const msg = std.fmt.allocPrint(state.allocator, "Memory saved. (ID: {d})", .{state.cortex.next_id - 1}) catch return;
        defer state.allocator.free(msg);
        state.tg.sendMessage(chat_id, msg) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "search")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory search <query>") catch {};
            return;
        }
        const results = state.cortex.search(sub_args) catch {
            state.tg.sendMessage(chat_id, "Search failed.") catch {};
            return;
        };
        defer state.allocator.free(results);

        if (results.len == 0) {
            state.tg.sendMessage(chat_id, "No memories found.") catch {};
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(state.allocator);
        const w = buf.writer(state.allocator);

        w.print("Found {d} memor{s}:\n\n", .{ results.len, if (results.len == 1) "y" else "ies" }) catch return;

        const show = @min(results.len, 10);
        for (results[0..show]) |entry| {
            const preview = if (entry.content.len > 150) entry.content[0..150] else entry.content;
            w.print("[{d}] {s}", .{ entry.id, preview }) catch continue;
            if (entry.content.len > 150) w.print("...", .{}) catch {};
            if (entry.tags.len > 0) {
                w.print("\n  Tags:", .{}) catch {};
                for (entry.tags) |tag| {
                    w.print(" #{s}", .{tag}) catch {};
                }
            }
            w.print("\n\n", .{}) catch {};
        }

        if (results.len > 10) {
            w.print("... and {d} more.", .{results.len - 10}) catch {};
        }

        state.tg.sendMessage(chat_id, buf.items) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "stats")) {
        const result = state.cortex.stats() catch {
            state.tg.sendMessage(chat_id, "Failed to get stats.") catch {};
            return;
        };
        defer state.allocator.free(result);
        state.tg.sendMessage(chat_id, result) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "clear")) {
        state.cortex.clear();
        state.tg.sendMessage(chat_id, "All memories cleared.") catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "delete")) {
        if (sub_args.len == 0) {
            state.tg.sendMessage(chat_id, "Usage: /memory delete <id>") catch {};
            return;
        }
        const id = std.fmt.parseInt(u64, sub_args, 10) catch {
            state.tg.sendMessage(chat_id, "Invalid ID. Use a numeric memory ID.") catch {};
            return;
        };
        if (state.cortex.delete(id)) {
            state.tg.sendMessage(chat_id, "Memory deleted.") catch {};
        } else {
            state.tg.sendMessage(chat_id, "Memory not found.") catch {};
        }
        return;
    }

    state.tg.sendMessage(chat_id, "Unknown subcommand. Use /memory for help.") catch {};
}

// ── Entry Point ───────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) std.log.err("Memory leak detected!", .{});
    }
    const allocator = gpa.allocator();

    std.log.info("Starting AI Agent Bot...", .{});

    // Determine working directory: CLI arg or current directory
    const cli_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, cli_args);

    const work_dir: []const u8 = if (cli_args.len > 1) cli_args[1] else ".";
    std.log.info("Working directory: {s}", .{work_dir});

    // Build paths relative to working directory
    const auth_path = try std.fs.path.join(allocator, &.{ work_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_path = try std.fs.path.join(allocator, &.{ work_dir, "models.json" });
    defer allocator.free(models_path);
    const users_path = try std.fs.path.join(allocator, &.{ work_dir, "allowed_users.json" });
    defer allocator.free(users_path);
    const agents_dir = try std.fs.path.join(allocator, &.{ work_dir, "agents" });
    defer allocator.free(agents_dir);
    const teams_dir = try std.fs.path.join(allocator, &.{ work_dir, "teams" });
    defer allocator.free(teams_dir);
    const skills_dir = try std.fs.path.join(allocator, &.{ work_dir, "skills" });
    defer allocator.free(skills_dir);
    const persist_dir = try std.fs.path.join(allocator, &.{ work_dir, "memory" });
    defer allocator.free(persist_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ work_dir, "workspaces" });
    defer allocator.free(workspace_dir);

    // Ensure directories exist
    for ([_][]const u8{ agents_dir, teams_dir, skills_dir, persist_dir, workspace_dir }) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Load configs (use path-aware loading)
    const auth_content = std.fs.cwd().readFileAlloc(allocator, auth_path, 1024 * 1024) catch |err| {
        std.log.err("Failed to read {s}: {s}", .{ auth_path, @errorName(err) });
        return err;
    };
    defer allocator.free(auth_content);

    const auth_parsed = std.json.parseFromSlice(config.AuthConfig, allocator, auth_content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse auth.json: {s}", .{@errorName(err)});
        return err;
    };
    defer auth_parsed.deinit();

    const models_content = std.fs.cwd().readFileAlloc(allocator, models_path, 1024 * 1024) catch |err| {
        std.log.err("Failed to read {s}: {s}", .{ models_path, @errorName(err) });
        return err;
    };
    defer allocator.free(models_content);

    const models_parsed = std.json.parseFromSlice(config.ModelConfig, allocator, models_content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse models.json: {s}", .{@errorName(err)});
        return err;
    };
    defer models_parsed.deinit();

    // Load allowed users
    const allowed_users = config.loadAllowedUsers(allocator) catch blk: {
        std.log.warn("Failed to load allowed_users, allowing all.", .{});
        break :blk allocator.alloc(i64, 0) catch return error.OutOfMemory;
    };
    defer allocator.free(allowed_users);

    // Initialize Telegram
    var tg_client = try telegram.TelegramClient.init(allocator, auth_parsed.value.telegram_bot_token, allowed_users);
    defer tg_client.deinit();

    tg_client.setMyCommands() catch |err| {
        std.log.warn("Failed to set commands: {s}", .{@errorName(err)});
    };

    // Initialize LLM client
    var llm_client = llm.LlmClient.init(allocator, auth_parsed.value.llm_api_key, models_parsed.value.llm_endpoint_url);
    defer llm_client.deinit();

    // Initialize tool registry
    var tool_registry = tools_mod.ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.register(tools_mod.BashTool.definition());

    // Load MCP servers (adds tools to registry dynamically)
    const mcp_config_path = try std.fs.path.join(allocator, &.{ work_dir, "mcp_servers.json" });
    defer allocator.free(mcp_config_path);
    var mcp_manager = try mcp.loadMcpServers(allocator, mcp_config_path);
    defer mcp_manager.deinit();

    mcp_manager.registerToolsInRegistry(&tool_registry) catch |err| {
        std.log.warn("Failed to register MCP tools: {s}", .{@errorName(err)});
    };

    if (mcp_manager.toolCount() > 0) {
        std.log.info("MCP: {d} tools loaded from {d} servers", .{ mcp_manager.toolCount(), mcp_manager.clients.count() });
    }

    // Load agents
    var agents = try agent_mod.loadAllAgents(allocator, agents_dir);
    defer {
        var it = agents.iterator();
        while (it.next()) |entry| agent_mod.freeAgent(allocator, entry.value_ptr.*);
        agents.deinit();
    }

    if (agents.count() == 0) {
        std.log.warn("No agents found in {s}", .{agents_dir});
    }

    // Load teams
    var teams = try team_mod.loadAllTeams(allocator, teams_dir);
    defer {
        var it = teams.iterator();
        while (it.next()) |entry| team_mod.freeTeam(allocator, entry.value_ptr.*);
        teams.deinit();
    }

    // Validate teams
    {
        var it = teams.iterator();
        while (it.next()) |entry| {
            if (!team_mod.validateTeam(entry.value_ptr.*, &agents)) {
                std.log.warn("Team '{s}' has missing agents", .{entry.key_ptr.*});
            }
        }
    }

    // Memory cortex
    var cortex = try memory_cortex.MemoryCortex.init(allocator, persist_dir);
    defer cortex.deinit();

    // Agent runtime
    var runtime = agent_mod.AgentRuntime.init(allocator, &llm_client, &tool_registry, &tg_client, skills_dir);
    runtime.mcp_manager = &mcp_manager;

    // Orchestrator
    var orch = orchestrator_mod.Orchestrator.init(
        allocator,
        &agents,
        &teams,
        &runtime,
        &tg_client,
        &llm_client,
        workspace_dir,
    );
    defer orch.deinit();

    // Shared conversations map (used by both direct mode and super agent)
    var conversations = std.AutoHashMap(i64, conversation.Conversation).init(allocator);

    // Super Agent (autonomous router)
    var super_agent = router.SuperAgent.init(
        allocator,
        &llm_client,
        &agents,
        &teams,
        &runtime,
        &orch,
        &tg_client,
        models_parsed.value.model_name,
        persist_dir,
        &conversations,
        workspace_dir,
        agents_dir,
        teams_dir,
        skills_dir,
    );
    defer super_agent.deinit();

    // Initialize file manager
    var file_manager = try FileManager.init(allocator, workspace_dir);
    defer file_manager.deinit();

    // App state
    var state = AppState{
        .allocator = allocator,
        .tg = &tg_client,
        .llm_client = &llm_client,
        .agents = agents,
        .teams = teams,
        .tool_registry = &tool_registry,
        .runtime = &runtime,
        .orchestrator = &orch,
        .chat_states = std.AutoHashMap(i64, ChatState).init(allocator),
        .conversations = conversations,
        .cortex = &cortex,
        .super_agent = &super_agent,
        .file_manager = file_manager,
        .work_dir = work_dir,
        .persist_dir = persist_dir,
        .max_history = 50,
        .max_context = 20,
        .last_reload_check = std.time.timestamp(),
    };
    defer {
        var conv_it = state.conversations.iterator();
        while (conv_it.next()) |entry| entry.value_ptr.deinit(allocator);
        state.conversations.deinit();
        var cs_it = state.chat_states.iterator();
        while (cs_it.next()) |entry| entry.value_ptr.deinit(allocator);
        state.chat_states.deinit();
    }

    std.log.info("Bot ready with {d} agents, {d} teams. Auto-routing enabled.", .{ agents.count(), teams.count() });

    // Main polling loop
    while (true) {
        // Hot reload check every 5 seconds
        const now = std.time.timestamp();
        if (now - state.last_reload_check >= 5) {
            agent_mod.reloadAgents(allocator, &state.agents);
            state.last_reload_check = now;
        }

        const messages = tg_client.pollUpdates(30) catch |err| {
            std.log.err("Poll error: {s}", .{@errorName(err)});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer {
            for (messages) |msg| msg.deinit(allocator);
            allocator.free(messages);
        }

        for (messages) |msg| {
            const text_content = msg.text orelse msg.caption orelse "";
            std.log.info("Message from {d}: {s} (has_file={})", .{ msg.user_id, text_content, msg.has_file });

            // Handle file downloads
            var file_metadata: ?FileMetadata = null;
            defer if (file_metadata) |meta| meta.deinit(state.allocator);

            if (msg.has_file) {
                file_metadata = handleFileMessage(&state, msg) catch |err| blk: {
                    std.log.err("Failed to handle file: {s}", .{@errorName(err)});
                    break :blk null;
                };
                if (file_metadata != null) {
                    std.log.info("File saved: {s}", .{file_metadata.?.path});
                }
            }

            // Ensure chat state exists (defaults to super_agent mode)
            if (!state.chat_states.contains(msg.chat_id)) {
                _ = state.getChatState(msg.chat_id) catch {};
            }

            if (isCommand(text_content)) {
                handleCommand(&state, msg.chat_id, text_content);
            } else {
                processMessage(&state, msg.chat_id, text_content, file_metadata);
            }
        }

        if (messages.len == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
