# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A self-organizing multi-agent orchestration system built as a Telegram bot in Zig 0.14+. The SuperAgent (router) can dynamically create agents and teams at runtime — no manual configuration needed. Agents have tools (bash execution) and skills (markdown knowledge files). Teams of agents collaborate on complex tasks coordinated by an orchestrator.

## Build & Test Commands

```bash
zig build              # Build the executable
zig build run          # Build and run (uses current dir as working dir)
zig build run -- /path/to/workdir  # Run with explicit working directory
zig build test         # Run all unit tests
zig build -Doptimize=ReleaseFast  # Release build
```

## Architecture

8-module structure with clear dependency layers:

### Layer 0: Infrastructure
- **`config.zig`** - Loads `auth.json`, `models.json`, `allowed_users.json`
- **`telegram.zig`** - Telegram Bot API client: polling, sendMessage, editMessage, typing, command menu
- **`llm.zig`** - LLM client supporting OpenAI and Anthropic formats, including **tool-calling** (`RichMessage`, `LlmResponse` with `ToolCall` parsing). `chatCompletion()` for simple text, `chatCompletionWithTools()` for agentic use.

### Layer 1: Tool System
- **`tools.zig`** - `ToolRegistry` + `BashTool`. Single bash tool executes commands via `std.process.Child`. Tools are serialized to OpenAI/Anthropic JSON schemas for LLM function calling. Skills (markdown files in `skills/`) are injected into system prompts at runtime -- no Zig code needed per tool.
- **`mcp.zig`** - MCP (Model Context Protocol) client. Spawns MCP servers as subprocesses, communicates via newline-delimited JSON-RPC 2.0 over STDIO. `McpClient` handles init handshake, tool discovery, and `tools/call`. `McpManager` aggregates tools from multiple servers and routes calls. Config loaded from `mcp_servers.json`.

### Layer 2: Agent Runtime
- **`conversation.zig`** - `Conversation` with `OwnedMessage` supporting `role`, `content`, `tool_call_id`, `tool_calls_json`. Persistence to JSON files.
- **`agent.zig`** - `AgentDef` (with `tool_names` and `skill_names`), `AgentRuntime` implementing the **tool-use loop**: LLM call -> execute tool calls -> feed results back -> repeat until text response. Hot-reload on file change.

### Layer 3: Team & Orchestration
- **`team.zig`** - `TeamDef` with roles (lead/member/reviewer) mapping to agent IDs. Hot-reload + discovery of new team files via `reloadTeams()`.
- **`orchestrator.zig`** - State machine: `gathering -> planning -> executing -> reviewing -> done`. PM agent gathers requirements, engineers execute subtasks, reviewer checks results.

### Layer 4: Application
- **`router.zig`** - `SuperAgent` autonomous router with **5 meta-tools**: `respond_directly`, `delegate_to_agent`, `start_team_task`, `create_agent`, `create_team`. Workspace-aware system prompt enables self-organization — the router can create new specialist agents and teams on the fly when no existing one fits.
- **`main.zig`** - Per-chat state (`ChatState` with `super_agent`, `direct_agent`, or `team_task` mode), command dispatch, working directory support via CLI arg.

## Working Directory

All runtime data lives in the working directory (CLI arg or `.`):
```
workdir/
  auth.json, models.json, allowed_users.json  # config
  agents/*.json   # agent definitions (with tools/skills fields)
  teams/*.json    # team definitions
  skills/*.md     # markdown skill files injected into agent prompts
  memory/         # conversation persistence
  workspaces/     # per-task working directories
  mcp_servers.json # MCP server configs (optional)
```

## MCP Server Config

Optional `mcp_servers.json` in working directory. Each entry spawns an MCP server subprocess:
```json
{
  "exa": {
    "command": "npx",
    "args": ["-y", "exa-mcp-server"],
    "env": { "EXA_API_KEY": "..." }
  }
}
```
MCP tools are auto-discovered at startup and registered alongside `bash` in the `ToolRegistry`. Agent runtime routes tool calls: MCP tools go to the appropriate server, `bash` runs locally.

## Agent JSON Schema

```json
{
  "id": "software_engineer",
  "name": "Software Engineer",
  "description": "...",
  "config": { "model_id": "...", "system_prompt": "...", "temperature": 0.3 },
  "tools": ["bash"],
  "skills": ["github.md", "web_dev.md"]
}
```
Agents without `tools` field work as simple persona chat (backward-compatible).

## Key Conventions

- All memory explicitly managed via `std.mem.Allocator` with GPA for leak detection
- Strings from parsed JSON are `dupe`'d for ownership, freed in `deinit`/`free*` functions
- API format auto-detected from model ID prefix: `claude`/`minimax` -> anthropic, else -> openai
- Tests colocated in each source file as Zig `test` blocks
- Tool output truncated to 50KB before sending to LLM context
- Agent tool-use loop capped at 15 iterations
