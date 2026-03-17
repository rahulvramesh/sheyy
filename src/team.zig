//! Team system: groups of agents that collaborate on tasks
const std = @import("std");
const agent_mod = @import("agent.zig");

pub const TeamRole = struct {
    agent_id: []const u8,
    role: []const u8, // "lead", "member", "reviewer"
    responsibilities: []const u8,
};

pub const TeamDef = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    roles: []TeamRole,
    workflow: []const u8,
    source_path: ?[]const u8,
    last_modified: ?i128,
};

/// JSON shape for teams/*.json
const TeamRoleJson = struct {
    agent_id: []const u8,
    role: []const u8,
    responsibilities: []const u8,
};

const TeamJson = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    roles: []const TeamRoleJson,
    workflow: ?[]const u8 = null,
};

pub fn loadTeam(allocator: std.mem.Allocator, file_path: []const u8) !*TeamDef {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(TeamJson, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const def = try allocator.create(TeamDef);
    errdefer allocator.destroy(def);

    const v = parsed.value;

    // Dupe roles
    const roles = try allocator.alloc(TeamRole, v.roles.len);
    for (v.roles, 0..) |r, i| {
        roles[i] = .{
            .agent_id = try allocator.dupe(u8, r.agent_id),
            .role = try allocator.dupe(u8, r.role),
            .responsibilities = try allocator.dupe(u8, r.responsibilities),
        };
    }

    def.* = .{
        .id = try allocator.dupe(u8, v.id),
        .name = try allocator.dupe(u8, v.name),
        .description = try allocator.dupe(u8, v.description),
        .roles = roles,
        .workflow = try allocator.dupe(u8, v.workflow orelse "Sequential: lead plans, members execute, reviewer checks"),
        .source_path = try allocator.dupe(u8, file_path),
        .last_modified = agent_mod.getFileMtime(file_path) catch null,
    };
    return def;
}

pub fn freeTeam(allocator: std.mem.Allocator, def: *TeamDef) void {
    allocator.free(def.id);
    allocator.free(def.name);
    allocator.free(def.description);
    for (def.roles) |role| {
        allocator.free(role.agent_id);
        allocator.free(role.role);
        allocator.free(role.responsibilities);
    }
    allocator.free(def.roles);
    allocator.free(def.workflow);
    if (def.source_path) |p| allocator.free(p);
    allocator.destroy(def);
}

pub fn loadAllTeams(allocator: std.mem.Allocator, dir_path: []const u8) !std.StringHashMap(*TeamDef) {
    var teams = std.StringHashMap(*TeamDef).init(allocator);
    errdefer teams.deinit();

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Cannot open teams dir {s}: {s}", .{ dir_path, @errorName(err) });
        return teams;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        const team_def = loadTeam(allocator, full_path) catch |err| {
            std.log.err("Failed to load team {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };

        teams.put(team_def.id, team_def) catch |err| {
            std.log.err("Failed to register team {s}: {s}", .{ team_def.id, @errorName(err) });
            freeTeam(allocator, team_def);
            continue;
        };

        std.log.info("Loaded team: {s} ({s}) with {d} roles", .{ team_def.name, team_def.id, team_def.roles.len });
    }

    return teams;
}

/// Validate that all agent_ids in the team exist in the agents map
pub fn validateTeam(team: *const TeamDef, agents: *const std.StringHashMap(*agent_mod.AgentDef)) bool {
    for (team.roles) |role| {
        if (!agents.contains(role.agent_id)) {
            std.log.warn("Team {s}: agent '{s}' (role: {s}) not found", .{ team.id, role.agent_id, role.role });
            return false;
        }
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "loadTeam parses valid JSON" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/test_teams";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const team_json =
        \\{"id": "dev_team",
        \\ "name": "Development Team",
        \\ "description": "A team of developers",
        \\ "roles": [
        \\   {"agent_id": "pm_agent", "role": "lead", "responsibilities": "Project management"},
        \\   {"agent_id": "dev_agent", "role": "member", "responsibilities": "Coding"}
        \\ ],
        \\ "workflow": "Agile workflow"}
    ;

    const file_path = try std.fs.path.join(allocator, &.{ test_dir, "dev_team.json" });
    defer allocator.free(file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = team_json,
    });

    const team = try loadTeam(allocator, file_path);
    defer freeTeam(allocator, team);

    try std.testing.expectEqualStrings("dev_team", team.id);
    try std.testing.expectEqualStrings("Development Team", team.name);
    try std.testing.expectEqualStrings("A team of developers", team.description);
    try std.testing.expectEqualStrings("Agile workflow", team.workflow);
    try std.testing.expectEqual(@as(usize, 2), team.roles.len);
    try std.testing.expectEqualStrings("pm_agent", team.roles[0].agent_id);
    try std.testing.expectEqualStrings("lead", team.roles[0].role);
    try std.testing.expectEqualStrings("dev_agent", team.roles[1].agent_id);
}

test "loadTeam uses default workflow" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/test_teams_default";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const team_json =
        \\{"id": "minimal_team",
        \\ "name": "Minimal Team",
        \\ "description": "Minimal team",
        \\ "roles": []}
    ;

    const file_path = try std.fs.path.join(allocator, &.{ test_dir, "minimal_team.json" });
    defer allocator.free(file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = team_json,
    });

    const team = try loadTeam(allocator, file_path);
    defer freeTeam(allocator, team);

    try std.testing.expectEqualStrings("minimal_team", team.id);
    try std.testing.expect(std.mem.indexOf(u8, team.workflow, "Sequential") != null);
}

test "loadAllTeams loads multiple teams" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/test_all_teams";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const team1_json =
        \\{"id": "team1", "name": "Team One", "description": "First team", "roles": []}
    ;
    const team2_json =
        \\{"id": "team2", "name": "Team Two", "description": "Second team", "roles": []}
    ;

    const path1 = try std.fs.path.join(allocator, &.{ test_dir, "team1.json" });
    defer allocator.free(path1);
    const path2 = try std.fs.path.join(allocator, &.{ test_dir, "team2.json" });
    defer allocator.free(path2);

    try std.fs.cwd().writeFile(.{ .sub_path = path1, .data = team1_json });
    try std.fs.cwd().writeFile(.{ .sub_path = path2, .data = team2_json });

    var teams = try loadAllTeams(allocator, test_dir);
    defer {
        var it = teams.iterator();
        while (it.next()) |entry| {
            freeTeam(allocator, entry.value_ptr.*);
        }
        teams.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), teams.count());
    try std.testing.expect(teams.get("team1") != null);
    try std.testing.expect(teams.get("team2") != null);
}

test "loadAllTeams handles non-existent directory" {
    const allocator = std.testing.allocator;

    var teams = try loadAllTeams(allocator, "/nonexistent/directory");
    defer teams.deinit();

    try std.testing.expectEqual(@as(usize, 0), teams.count());
}

test "loadAllTeams skips invalid JSON files" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/test_teams_invalid";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const valid_json =
        \\{"id": "valid", "name": "Valid Team", "description": "A valid team", "roles": []}
    ;
    const invalid_json = "not valid json";

    const valid_path = try std.fs.path.join(allocator, &.{ test_dir, "valid.json" });
    defer allocator.free(valid_path);
    const invalid_path = try std.fs.path.join(allocator, &.{ test_dir, "invalid.json" });
    defer allocator.free(invalid_path);

    try std.fs.cwd().writeFile(.{ .sub_path = valid_path, .data = valid_json });
    try std.fs.cwd().writeFile(.{ .sub_path = invalid_path, .data = invalid_json });

    var teams = try loadAllTeams(allocator, test_dir);
    defer {
        var it = teams.iterator();
        while (it.next()) |entry| {
            freeTeam(allocator, entry.value_ptr.*);
        }
        teams.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), teams.count());
    try std.testing.expect(teams.get("valid") != null);
}

test "loadAllTeams skips non-JSON files" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/test_teams_skip";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const team_json =
        \\{"id": "team", "name": "Team", "description": "A team", "roles": []}
    ;

    const json_path = try std.fs.path.join(allocator, &.{ test_dir, "team.json" });
    defer allocator.free(json_path);
    const txt_path = try std.fs.path.join(allocator, &.{ test_dir, "readme.txt" });
    defer allocator.free(txt_path);

    try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = team_json });
    try std.fs.cwd().writeFile(.{ .sub_path = txt_path, .data = "This is not a team" });

    var teams = try loadAllTeams(allocator, test_dir);
    defer {
        var it = teams.iterator();
        while (it.next()) |entry| {
            freeTeam(allocator, entry.value_ptr.*);
        }
        teams.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), teams.count());
}

test "validateTeam returns true for valid team" {
    const allocator = std.testing.allocator;

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const agent_def = try allocator.create(agent_mod.AgentDef);
    defer {
        allocator.free(agent_def.id);
        allocator.free(agent_def.name);
        allocator.free(agent_def.description);
        allocator.free(agent_def.config.model_id);
        allocator.free(agent_def.config.system_prompt);
        if (agent_def.tools) |t| allocator.free(t);
        if (agent_def.skills) |s| allocator.free(s);
        allocator.destroy(agent_def);
    }

    agent_def.* = .{
        .id = try allocator.dupe(u8, "pm_agent"),
        .name = try allocator.dupe(u8, "PM Agent"),
        .description = try allocator.dupe(u8, "Project Manager"),
        .config = .{
            .model_id = try allocator.dupe(u8, "gpt-4o"),
            .system_prompt = try allocator.dupe(u8, "You are a PM"),
            .temperature = 0.5,
        },
        .tools = null,
        .skills = null,
        .source_path = null,
        .last_modified = null,
    };

    try agents.put(agent_def.id, agent_def);

    const team = try allocator.create(TeamDef);
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
        if (team.source_path) |p| allocator.free(p);
        allocator.destroy(team);
    }

    const roles = try allocator.alloc(TeamRole, 1);
    roles[0] = .{
        .agent_id = try allocator.dupe(u8, "pm_agent"),
        .role = try allocator.dupe(u8, "lead"),
        .responsibilities = try allocator.dupe(u8, "Manage the project"),
    };

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "A test team"),
        .roles = roles,
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };

    try std.testing.expect(validateTeam(team, &agents));
}

test "validateTeam returns false for missing agent" {
    const allocator = std.testing.allocator;

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const team = try allocator.create(TeamDef);
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
        if (team.source_path) |p| allocator.free(p);
        allocator.destroy(team);
    }

    const roles = try allocator.alloc(TeamRole, 1);
    roles[0] = .{
        .agent_id = try allocator.dupe(u8, "missing_agent"),
        .role = try allocator.dupe(u8, "lead"),
        .responsibilities = try allocator.dupe(u8, "Manage the project"),
    };

    team.* = .{
        .id = try allocator.dupe(u8, "test_team"),
        .name = try allocator.dupe(u8, "Test Team"),
        .description = try allocator.dupe(u8, "A test team"),
        .roles = roles,
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };

    try std.testing.expect(!validateTeam(team, &agents));
}

test "validateTeam handles empty team" {
    const allocator = std.testing.allocator;

    var agents = std.StringHashMap(*agent_mod.AgentDef).init(allocator);
    defer agents.deinit();

    const team = try allocator.create(TeamDef);
    defer {
        allocator.free(team.id);
        allocator.free(team.name);
        allocator.free(team.description);
        allocator.free(team.roles);
        allocator.free(team.workflow);
        if (team.source_path) |p| allocator.free(p);
        allocator.destroy(team);
    }

    team.* = .{
        .id = try allocator.dupe(u8, "empty_team"),
        .name = try allocator.dupe(u8, "Empty Team"),
        .description = try allocator.dupe(u8, "An empty team"),
        .roles = try allocator.alloc(TeamRole, 0),
        .workflow = try allocator.dupe(u8, "Test workflow"),
        .source_path = null,
        .last_modified = null,
    };

    try std.testing.expect(validateTeam(team, &agents));
}

test "freeTeam releases all memory" {
    const allocator = std.testing.allocator;

    const team = try allocator.create(TeamDef);
    const roles = try allocator.alloc(TeamRole, 1);
    roles[0] = .{
        .agent_id = try allocator.dupe(u8, "agent1"),
        .role = try allocator.dupe(u8, "lead"),
        .responsibilities = try allocator.dupe(u8, "Responsibilities"),
    };

    team.* = .{
        .id = try allocator.dupe(u8, "team1"),
        .name = try allocator.dupe(u8, "Team One"),
        .description = try allocator.dupe(u8, "Description"),
        .roles = roles,
        .workflow = try allocator.dupe(u8, "Workflow"),
        .source_path = try allocator.dupe(u8, "/path/to/team.json"),
        .last_modified = 1234567890,
    };

    freeTeam(allocator, team);
}
