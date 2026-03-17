//! Orchestrator: coordinates multi-agent task execution
const std = @import("std");
const agent_mod = @import("agent.zig");
const team_mod = @import("team.zig");
const conversation = @import("conversation.zig");
const telegram = @import("telegram.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");

// ── Task & State ──────────────────────────────────────────────────

pub const TaskState = enum {
    pending,
    in_progress,
    completed,
    failed,
};

pub const SubTask = struct {
    id: usize,
    title: []const u8,
    description: []const u8,
    assigned_role: []const u8, // maps to team role -> agent_id
    state: TaskState,
    result: ?[]const u8,
};

pub const OrchestratorState = enum {
    idle,
    gathering, // PM asking clarifying questions
    planning, // PM creating task plan
    executing, // agents working
    reviewing, // reviewer checking
    done,
    failed,
};

pub const TaskSession = struct {
    allocator: std.mem.Allocator,
    chat_id: i64,
    state: OrchestratorState,
    team: *const team_mod.TeamDef,
    user_request: []const u8,
    subtasks: std.ArrayList(SubTask),
    pm_conversation: conversation.Conversation,
    working_dir: []const u8,
    progress_msg_id: ?i64,
    current_subtask: usize,

    pub fn init(allocator: std.mem.Allocator, chat_id: i64, team: *const team_mod.TeamDef, request: []const u8, working_dir: []const u8) !TaskSession {
        return .{
            .allocator = allocator,
            .chat_id = chat_id,
            .state = .gathering,
            .team = team,
            .user_request = try allocator.dupe(u8, request),
            .subtasks = .empty,
            .pm_conversation = conversation.Conversation.init(),
            .working_dir = try allocator.dupe(u8, working_dir),
            .progress_msg_id = null,
            .current_subtask = 0,
        };
    }

    pub fn deinit(self: *TaskSession) void {
        self.allocator.free(self.user_request);
        for (self.subtasks.items) |task| {
            self.allocator.free(task.title);
            self.allocator.free(task.description);
            self.allocator.free(task.assigned_role);
            if (task.result) |r| self.allocator.free(r);
        }
        self.subtasks.deinit(self.allocator);
        self.pm_conversation.deinit(self.allocator);
        self.allocator.free(self.working_dir);
    }
};

// ── Orchestrator ──────────────────────────────────────────────────

pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    agents: *std.StringHashMap(*agent_mod.AgentDef),
    teams: *std.StringHashMap(*team_mod.TeamDef),
    runtime: *agent_mod.AgentRuntime,
    tg: *telegram.TelegramClient,
    llm_client: *llm.LlmClient,
    active_sessions: std.AutoHashMap(i64, *TaskSession),
    base_workspace_dir: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        agents: *std.StringHashMap(*agent_mod.AgentDef),
        teams: *std.StringHashMap(*team_mod.TeamDef),
        runtime: *agent_mod.AgentRuntime,
        tg: *telegram.TelegramClient,
        llm_client: *llm.LlmClient,
        base_workspace_dir: []const u8,
    ) Orchestrator {
        return .{
            .allocator = allocator,
            .agents = agents,
            .teams = teams,
            .runtime = runtime,
            .tg = tg,
            .llm_client = llm_client,
            .active_sessions = std.AutoHashMap(i64, *TaskSession).init(allocator),
            .base_workspace_dir = base_workspace_dir,
        };
    }

    pub fn deinit(self: *Orchestrator) void {
        var it = self.active_sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_sessions.deinit();
    }

    pub fn getSession(self: *Orchestrator, chat_id: i64) ?*TaskSession {
        return self.active_sessions.get(chat_id);
    }

    /// Start a new task with a team
    pub fn startTask(self: *Orchestrator, chat_id: i64, team: *const team_mod.TeamDef, request: []const u8) !void {
        // Create workspace directory for this task
        const timestamp = std.time.timestamp();
        const work_dir = try std.fmt.allocPrint(self.allocator, "{s}/task_{d}_{d}", .{ self.base_workspace_dir, chat_id, timestamp });
        defer self.allocator.free(work_dir);
        std.fs.cwd().makePath(work_dir) catch {};

        const session = try self.allocator.create(TaskSession);
        session.* = try TaskSession.init(self.allocator, chat_id, team, request, work_dir);

        try self.active_sessions.put(chat_id, session);

        // Send initial status
        const status_msg = try std.fmt.allocPrint(self.allocator, "[Orchestrator] Task started with team: {s}\nGathering requirements...", .{team.name});
        defer self.allocator.free(status_msg);
        const msg_id = self.tg.sendMessageReturningId(chat_id, status_msg) catch 0;
        session.progress_msg_id = if (msg_id != 0) msg_id else null;

        // Run the gathering phase with PM
        try self.runGathering(session);
    }

    /// Handle a message for a chat that has an active session
    pub fn handleMessage(self: *Orchestrator, session: *TaskSession, text: []const u8) !void {
        switch (session.state) {
            .gathering => {
                // User is answering PM's questions
                try session.pm_conversation.addMessage(self.allocator, "user", text);
                try self.runGathering(session);
            },
            .executing, .planning, .reviewing => {
                // Task is in progress, acknowledge
                self.tg.sendMessage(session.chat_id, "Task is in progress. Use /task to check status.") catch {};
            },
            .done, .failed => {
                self.tg.sendMessage(session.chat_id, "Task is complete. Start a new one with /team <id> <request>.") catch {};
            },
            .idle => {},
        }
    }

    /// Cancel the active task for a chat
    pub fn cancelTask(self: *Orchestrator, chat_id: i64) void {
        if (self.active_sessions.fetchRemove(chat_id)) |kv| {
            var session = kv.value;
            session.deinit();
            self.allocator.destroy(session);
            self.tg.sendMessage(chat_id, "Task cancelled.") catch {};
        }
    }

    // ── Phases ─────────────────────────────────────────────────────

    fn runGathering(self: *Orchestrator, session: *TaskSession) !void {
        // Find the lead/PM agent
        const pm_agent_id = self.findRoleAgentId(session.team, "lead") orelse {
            // No PM, skip to planning
            session.state = .planning;
            try self.runPlanning(session);
            return;
        };

        const pm_def = self.agents.get(pm_agent_id) orelse {
            self.tg.sendMessage(session.chat_id, "Error: PM agent not found.") catch {};
            session.state = .failed;
            return;
        };

        // Build PM prompt for gathering
        const gather_prompt = try std.fmt.allocPrint(self.allocator,
            \\You are a project manager gathering requirements for a task.
            \\
            \\The user's request: {s}
            \\
            \\Your job:
            \\1. Ask clarifying questions if the request is unclear (max 3 questions at a time)
            \\2. When you have enough information, respond with EXACTLY this format:
            \\
            \\PLAN_READY
            \\Then list the subtasks as:
            \\SUBTASK: <title> | <description> | <role: member/reviewer>
            \\
            \\Keep it practical and actionable. The team workflow is: {s}
            \\Available roles: {s}
        , .{
            session.user_request,
            session.team.workflow,
            try self.formatRoles(session.team),
        });
        defer self.allocator.free(gather_prompt);

        // If PM conversation is empty, seed it
        if (session.pm_conversation.messages.items.len == 0) {
            try session.pm_conversation.addMessage(self.allocator, "user", gather_prompt);
        }

        // Run PM agent
        const pm_response = self.runtime.run(
            pm_def,
            &session.pm_conversation,
            session.chat_id,
            session.progress_msg_id,
            null,
        ) catch |err| {
            std.log.err("PM agent error: {s}", .{@errorName(err)});
            self.tg.sendMessage(session.chat_id, "Error during planning phase.") catch {};
            session.state = .failed;
            return;
        };
        defer self.allocator.free(pm_response);

        // Check if PM says plan is ready
        if (std.mem.indexOf(u8, pm_response, "PLAN_READY") != null) {
            // Parse subtasks from PM response
            try self.parsePlan(session, pm_response);
            session.state = .executing;

            // Notify user
            const plan_msg = try self.formatPlanMessage(session);
            defer self.allocator.free(plan_msg);
            self.tg.sendMessage(session.chat_id, plan_msg) catch {};

            // Start execution
            try self.runExecution(session);
        } else {
            // PM is asking questions - forward to user
            const pm_msg = try std.fmt.allocPrint(self.allocator, "[PM] {s}", .{pm_response});
            defer self.allocator.free(pm_msg);
            self.tg.sendMessage(session.chat_id, pm_msg) catch {};
            // Stay in gathering state, wait for user reply
        }
    }

    fn runPlanning(self: *Orchestrator, session: *TaskSession) !void {
        // Auto-create a single subtask if no PM
        const title = try self.allocator.dupe(u8, "Execute task");
        const desc = try self.allocator.dupe(u8, session.user_request);
        const role = try self.allocator.dupe(u8, "member");

        try session.subtasks.append(self.allocator, .{
            .id = 0,
            .title = title,
            .description = desc,
            .assigned_role = role,
            .state = .pending,
            .result = null,
        });

        session.state = .executing;
        try self.runExecution(session);
    }

    fn runExecution(self: *Orchestrator, session: *TaskSession) !void {
        for (session.subtasks.items, 0..) |*subtask, idx| {
            if (subtask.state != .pending) continue;

            subtask.state = .in_progress;
            session.current_subtask = idx;

            // Find the agent for this role
            const agent_id = self.findRoleAgentId(session.team, subtask.assigned_role) orelse {
                subtask.state = .failed;
                subtask.result = try self.allocator.dupe(u8, "No agent found for role");
                continue;
            };

            const agent_def = self.agents.get(agent_id) orelse {
                subtask.state = .failed;
                subtask.result = try self.allocator.dupe(u8, "Agent not found");
                continue;
            };

            // Progress update
            const progress = try std.fmt.allocPrint(self.allocator, "[{s}] Working on: {s} ({d}/{d})", .{
                agent_def.name, subtask.title, idx + 1, session.subtasks.items.len,
            });
            defer self.allocator.free(progress);
            self.tg.sendMessage(session.chat_id, progress) catch {};

            // Create a fresh conversation for this subtask
            var subtask_conv = conversation.Conversation.init();
            defer subtask_conv.deinit(self.allocator);

            const task_prompt = try std.fmt.allocPrint(self.allocator,
                \\Task: {s}
                \\
                \\Description: {s}
                \\
                \\Working directory: {s}
                \\
                \\Complete this task using the available tools. When done, summarize what you did.
            , .{ subtask.title, subtask.description, session.working_dir });
            defer self.allocator.free(task_prompt);

            try subtask_conv.addMessage(self.allocator, "user", task_prompt);

            // Run agent
            const result = self.runtime.run(
                agent_def,
                &subtask_conv,
                session.chat_id,
                session.progress_msg_id,
                session.working_dir,
            ) catch |err| {
                subtask.state = .failed;
                subtask.result = try std.fmt.allocPrint(self.allocator, "Agent error: {s}", .{@errorName(err)});
                continue;
            };

            subtask.state = .completed;
            subtask.result = result;
        }

        // Check if we need review
        if (self.findRoleAgentId(session.team, "reviewer") != null) {
            session.state = .reviewing;
            try self.runReview(session);
        } else {
            session.state = .done;
            try self.deliverResults(session);
        }
    }

    fn runReview(self: *Orchestrator, session: *TaskSession) !void {
        const reviewer_id = self.findRoleAgentId(session.team, "reviewer") orelse {
            session.state = .done;
            try self.deliverResults(session);
            return;
        };

        const reviewer_def = self.agents.get(reviewer_id) orelse {
            session.state = .done;
            try self.deliverResults(session);
            return;
        };

        self.tg.sendMessage(session.chat_id, "[Reviewer] Reviewing completed work...") catch {};

        // Build review prompt with all subtask results
        var review_buf: std.ArrayList(u8) = .empty;
        defer review_buf.deinit(self.allocator);
        const w = review_buf.writer(self.allocator);

        try w.print("Review the following completed tasks:\n\n", .{});
        for (session.subtasks.items) |subtask| {
            try w.print("## {s}\nStatus: {s}\nResult: {s}\n\n", .{
                subtask.title,
                @tagName(subtask.state),
                subtask.result orelse "no output",
            });
        }
        try w.print("Working directory: {s}\nProvide a brief review and any issues found.", .{session.working_dir});

        var review_conv = conversation.Conversation.init();
        defer review_conv.deinit(self.allocator);
        try review_conv.addMessage(self.allocator, "user", review_buf.items);

        const review_result = self.runtime.run(
            reviewer_def,
            &review_conv,
            session.chat_id,
            session.progress_msg_id,
            session.working_dir,
        ) catch |err| {
            std.log.err("Review error: {s}", .{@errorName(err)});
            session.state = .done;
            try self.deliverResults(session);
            return;
        };
        defer self.allocator.free(review_result);

        // Send review to user
        const review_msg = try std.fmt.allocPrint(self.allocator, "[Reviewer] {s}", .{review_result});
        defer self.allocator.free(review_msg);
        self.tg.sendMessage(session.chat_id, review_msg) catch {};

        session.state = .done;
        try self.deliverResults(session);
    }

    fn deliverResults(self: *Orchestrator, session: *TaskSession) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("Task Complete!\n\nResults:\n", .{});
        for (session.subtasks.items) |subtask| {
            const icon: []const u8 = if (subtask.state == .completed) "[done]" else "[fail]";
            try w.print("\n{s} {s}\n", .{ icon, subtask.title });
            if (subtask.result) |r| {
                const preview = if (r.len > 500) r[0..500] else r;
                try w.print("{s}", .{preview});
                if (r.len > 500) try w.print("...", .{});
                try w.print("\n", .{});
            }
        }
        try w.print("\nWorkspace: {s}", .{session.working_dir});

        self.tg.sendMessage(session.chat_id, buf.items) catch {};
    }

    // ── Helpers ────────────────────────────────────────────────────

    fn findRoleAgentId(self: *Orchestrator, team: *const team_mod.TeamDef, role: []const u8) ?[]const u8 {
        _ = self;
        for (team.roles) |r| {
            if (std.mem.eql(u8, r.role, role)) return r.agent_id;
        }
        return null;
    }

    fn formatRoles(self: *Orchestrator, team: *const team_mod.TeamDef) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        for (team.roles, 0..) |role, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s} ({s})", .{ role.role, role.agent_id });
        }
        return try self.allocator.dupe(u8, buf.items);
    }

    fn parsePlan(self: *Orchestrator, session: *TaskSession, response: []const u8) !void {
        var lines = std.mem.splitScalar(u8, response, '\n');
        var id: usize = 0;
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "SUBTASK:")) continue;

            const content = std.mem.trimLeft(u8, line["SUBTASK:".len..], " ");
            var parts = std.mem.splitScalar(u8, content, '|');

            const title = std.mem.trim(u8, parts.next() orelse continue, " ");
            const desc = std.mem.trim(u8, parts.next() orelse title, " ");
            const role = std.mem.trim(u8, parts.next() orelse "member", " ");

            try session.subtasks.append(self.allocator, .{
                .id = id,
                .title = try self.allocator.dupe(u8, title),
                .description = try self.allocator.dupe(u8, desc),
                .assigned_role = try self.allocator.dupe(u8, role),
                .state = .pending,
                .result = null,
            });
            id += 1;
        }

        // If no subtasks were parsed, create one default
        if (session.subtasks.items.len == 0) {
            try session.subtasks.append(self.allocator, .{
                .id = 0,
                .title = try self.allocator.dupe(u8, "Execute task"),
                .description = try self.allocator.dupe(u8, session.user_request),
                .assigned_role = try self.allocator.dupe(u8, "member"),
                .state = .pending,
                .result = null,
            });
        }
    }

    fn formatPlanMessage(self: *Orchestrator, session: *const TaskSession) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("[Orchestrator] Plan ready ({d} subtasks):\n\n", .{session.subtasks.items.len});
        for (session.subtasks.items) |subtask| {
            try w.print("  {d}. {s} (assigned: {s})\n", .{ subtask.id + 1, subtask.title, subtask.assigned_role });
        }
        try w.print("\nStarting execution...", .{});
        return try self.allocator.dupe(u8, buf.items);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "TaskSession init and deinit" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = try allocator.alloc(team_mod.TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var session = try TaskSession.init(allocator, 12345, team, "Test request", "/tmp/work");
    defer session.deinit();

    try std.testing.expectEqual(@as(i64, 12345), session.chat_id);
    try std.testing.expectEqual(OrchestratorState.gathering, session.state);
    try std.testing.expectEqualStrings("Test request", session.user_request);
    try std.testing.expectEqualStrings("/tmp/work", session.working_dir);
    try std.testing.expectEqual(@as(usize, 0), session.subtasks.items.len);
}

test "Orchestrator init and deinit" {
    const allocator = std.testing.allocator;

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    var teams = std.StringHashMap(*team_mod.TeamDef).init(allocator);
    defer teams.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        &teams,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    try std.testing.expectEqual(@as(usize, 0), orchestrator.active_sessions.count());
}

test "Orchestrator getSession returns null for unknown chat" {
    const allocator = std.testing.allocator;

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    var teams = std.StringHashMap(*team_mod.TeamDef).init(allocator);
    defer teams.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        &teams,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    try std.testing.expect(orchestrator.getSession(99999) == null);
}

test "findRoleAgentId finds matching role" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    const roles = try allocator.alloc(team_mod.TeamRole, 3);
    roles[0] = .{
        .agent_id = try allocator.dupe(u8, "pm_1"),
        .role = try allocator.dupe(u8, "lead"),
        .responsibilities = try allocator.dupe(u8, "PM duties"),
    };
    roles[1] = .{
        .agent_id = try allocator.dupe(u8, "dev_1"),
        .role = try allocator.dupe(u8, "member"),
        .responsibilities = try allocator.dupe(u8, "Coding"),
    };
    roles[2] = .{
        .agent_id = try allocator.dupe(u8, "reviewer_1"),
        .role = try allocator.dupe(u8, "reviewer"),
        .responsibilities = try allocator.dupe(u8, "Reviewing"),
    };

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = roles,
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        for (team.roles) |r| {
            allocator.free(r.agent_id);
            allocator.free(r.role);
            allocator.free(r.responsibilities);
        }
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const lead_id = orchestrator.findRoleAgentId(team, "lead");
    try std.testing.expect(lead_id != null);
    try std.testing.expectEqualStrings("pm_1", lead_id.?);

    const member_id = orchestrator.findRoleAgentId(team, "member");
    try std.testing.expect(member_id != null);
    try std.testing.expectEqualStrings("dev_1", member_id.?);

    const reviewer_id = orchestrator.findRoleAgentId(team, "reviewer");
    try std.testing.expect(reviewer_id != null);
    try std.testing.expectEqualStrings("reviewer_1", reviewer_id.?);

    const unknown_id = orchestrator.findRoleAgentId(team, "unknown");
    try std.testing.expect(unknown_id == null);
}

test "parsePlan extracts subtasks from PM response" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = try allocator.alloc(team_mod.TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var session = try TaskSession.init(allocator, 12345, team, "Create a web app", "/tmp/work");
    defer session.deinit();

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const pm_response =
        \\PLAN_READY
        \\Some explanation here
        \\SUBTASK: Setup project | Initialize the repository and project structure | member
        \\SUBTASK: Implement API | Create REST endpoints for the application | member
        \\SUBTASK: Review code | Check code quality and best practices | reviewer
    ;

    try orchestrator.parsePlan(&session, pm_response);

    try std.testing.expectEqual(@as(usize, 3), session.subtasks.items.len);

    try std.testing.expectEqualStrings("Setup project", session.subtasks.items[0].title);
    try std.testing.expectEqualStrings("Initialize the repository and project structure", session.subtasks.items[0].description);
    try std.testing.expectEqualStrings("member", session.subtasks.items[0].assigned_role);

    try std.testing.expectEqualStrings("Implement API", session.subtasks.items[1].title);
    try std.testing.expectEqualStrings("Create REST endpoints for the application", session.subtasks.items[1].description);

    try std.testing.expectEqualStrings("Review code", session.subtasks.items[2].title);
    try std.testing.expectEqualStrings("reviewer", session.subtasks.items[2].assigned_role);
}

test "parsePlan creates default subtask when none parsed" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = try allocator.alloc(team_mod.TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var session = try TaskSession.init(allocator, 12345, team, "Create a web app", "/tmp/work");
    defer session.deinit();

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const pm_response = "PLAN_READY\nBut no subtask format found";

    try orchestrator.parsePlan(&session, pm_response);

    try std.testing.expectEqual(@as(usize, 1), session.subtasks.items.len);
    try std.testing.expectEqualStrings("Execute task", session.subtasks.items[0].title);
    try std.testing.expectEqualStrings("Create a web app", session.subtasks.items[0].description);
    try std.testing.expectEqualStrings("member", session.subtasks.items[0].assigned_role);
}

test "formatPlanMessage generates correct output" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = try allocator.alloc(team_mod.TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var session = try TaskSession.init(allocator, 12345, team, "Test request", "/tmp/work");
    defer session.deinit();

    try session.subtasks.append(allocator, .{
        .id = 0,
        .title = try allocator.dupe(u8, "Task 1"),
        .description = try allocator.dupe(u8, "First task"),
        .assigned_role = try allocator.dupe(u8, "member"),
        .state = .pending,
        .result = null,
    });
    try session.subtasks.append(allocator, .{
        .id = 1,
        .title = try allocator.dupe(u8, "Task 2"),
        .description = try allocator.dupe(u8, "Second task"),
        .assigned_role = try allocator.dupe(u8, "reviewer"),
        .state = .pending,
        .result = null,
    });

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const message = try orchestrator.formatPlanMessage(&session);
    defer allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "Plan ready (2 subtasks)") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "1. Task 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "2. Task 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "assigned: member") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "assigned: reviewer") != null);
}

test "formatRoles generates role list" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    const roles = try allocator.alloc(team_mod.TeamRole, 2);
    roles[0] = .{
        .agent_id = try allocator.dupe(u8, "agent_1"),
        .role = try allocator.dupe(u8, "lead"),
        .responsibilities = try allocator.dupe(u8, "Leading"),
    };
    roles[1] = .{
        .agent_id = try allocator.dupe(u8, "agent_2"),
        .role = try allocator.dupe(u8, "member"),
        .responsibilities = try allocator.dupe(u8, "Working"),
    };

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = roles,
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        for (team.roles) |r| {
            allocator.free(r.agent_id);
            allocator.free(r.role);
            allocator.free(r.responsibilities);
        }
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const roles_str = try orchestrator.formatRoles(team);
    defer allocator.free(roles_str);

    try std.testing.expect(std.mem.indexOf(u8, roles_str, "lead (agent_1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, roles_str, "member (agent_2)") != null);
}

test "TaskState transitions" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TaskState.pending));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TaskState.in_progress));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TaskState.completed));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TaskState.failed));
}

test "OrchestratorState enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(OrchestratorState.idle));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(OrchestratorState.gathering));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(OrchestratorState.planning));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(OrchestratorState.executing));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(OrchestratorState.reviewing));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(OrchestratorState.done));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(OrchestratorState.failed));
}

test "parsePlan handles subtask with missing role" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(team_mod.TeamDef);
    defer allocator.destroy(team);

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "Test team"),
        .roles = try allocator.alloc(team_mod.TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
    }

    var session = try TaskSession.init(allocator, 12345, team, "Test request", "/tmp/work");
    defer session.deinit();

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const runtime = try allocator.create(agent_mod.AgentRuntime);
    defer allocator.destroy(runtime);

    const tg = try allocator.create(telegram.TelegramClient);
    defer allocator.destroy(tg);

    const llm_client = try allocator.create(llm.LlmClient);
    defer allocator.destroy(llm_client);

    var orchestrator = Orchestrator.init(
        allocator,
        &agents,
        undefined,
        runtime,
        tg,
        llm_client,
        "/tmp/workspace",
    );
    defer orchestrator.deinit();

    const pm_response = "PLAN_READY\nSUBTASK: Simple Task | Just a description";

    try orchestrator.parsePlan(&session, pm_response);

    try std.testing.expectEqual(@as(usize, 1), session.subtasks.items.len);
    try std.testing.expectEqualStrings("Simple Task", session.subtasks.items[0].title);
    try std.testing.expectEqualStrings("Just a description", session.subtasks.items[0].description);
    try std.testing.expectEqualStrings("member", session.subtasks.items[0].assigned_role);
}
