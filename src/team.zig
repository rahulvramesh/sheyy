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
