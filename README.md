# SheyyBot v3.0 - Self-Organizing Multi-Agent System

A self-organizing multi-agent Telegram bot built in Zig 0.15+. SheyyBot autonomously creates specialized agents and teams at runtime -- no manual configuration required. Give it a task and it assembles the right specialists on the fly.

## Overview

SheyyBot goes beyond static agent routing. Its SuperAgent router has meta-tools that let it dynamically create new agents, form teams, and delegate work -- all without human intervention.

- **Self-Organizing** - The router creates new agents and teams on demand for any domain
- **5 Meta-Tools** - respond_directly, delegate_to_agent, start_team_task, create_agent, create_team
- **Team Hot-Reload** - Newly created teams are discovered and usable immediately
- **Workspace Awareness** - The router understands the agents/, teams/, and skills/ directories
- **Autonomous SDLC** - For software projects, it creates PM, architect, dev, QA, and DevOps agents with a coordinating team automatically
- **MCP Integration** - External tool servers via Model Context Protocol
- **Streaming Responses** - Real-time token streaming for responsive UX
- **Persistent Memory** - Conversation history and semantic memory with TF-IDF retrieval

## Architecture

```
Layer 4: Application
  main.zig              - Entry point, per-chat state, command dispatch
  router.zig            - SuperAgent with 5 meta-tools (routing, agent/team creation)

Layer 3: Team & Orchestration
  orchestrator.zig      - Multi-agent task coordination (state machine)
  team.zig              - Team definitions and role management

Layer 2: Agent Runtime
  agent.zig             - Agent execution with tool-use loop (up to 15 iterations)
  conversation.zig      - Message history persistence

Layer 1: Tool System
  tools.zig             - Tool registry (bash) with JSON schema generation
  mcp.zig               - MCP client for external tool servers

Layer 0: Infrastructure
  config.zig            - Configuration management (auth, models, allowed users)
  telegram.zig          - Telegram Bot API client (polling, messaging)
  llm.zig               - LLM client (OpenAI + Anthropic formats, tool-calling)
```

## Quick Start

### Prerequisites

- Zig 0.15.2 or later
- Telegram Bot Token (from @BotFather)
- OpenAI-compatible LLM API key

### Installation

```bash
# Clone the repository
git clone https://github.com/rahulvramesh/sheyy.git
cd sheyy

# Option 1: One-command setup
./install.sh

# Option 2: Manual build
zig build -Doptimize=ReleaseFast
```

### Configuration

#### auth.json
```json
{
  "telegram_bot_token": "YOUR_BOT_TOKEN",
  "llm_api_key": "YOUR_LLM_API_KEY"
}
```

#### models.json
```json
{
  "llm_endpoint_url": "https://api.openai.com/v1/chat/completions",
  "model_name": "gpt-4o-mini",
  "enable_streaming": true
}
```

#### allowed_users.json
```json
[123456789, 987654321]
```

### Running

```bash
# Run with current directory as working directory
zig build run

# Run with explicit working directory
zig build run -- /path/to/workdir
```

## How Self-Organization Works

The SuperAgent router is the entry point for every message. It uses an LLM with five meta-tools to decide what to do:

| Meta-Tool | Purpose |
|-----------|---------|
| `respond_directly` | Handle greetings, simple questions, general knowledge |
| `delegate_to_agent` | Route to a specialist agent for focused tasks |
| `start_team_task` | Launch a multi-agent team for complex projects |
| `create_agent` | Create a new specialist agent when none fits the task |
| `create_team` | Design and create a new team with roles and workflow |

The router is workspace-aware. It knows which agents, teams, and skills already exist and only creates new ones when needed. Created agents and teams are written to the agents/ and teams/ directories and are available immediately.

### Example: SDLC Project

When you ask SheyyBot to build a web application, the router may:

1. Create agents: project_manager, architect, frontend_dev, backend_dev, qa_engineer, devops
2. Create a team with those agents assigned lead/member/reviewer roles
3. Start the team task, which triggers the orchestrator state machine:
   - **Gathering** - PM agent gathers requirements
   - **Planning** - PM creates subtasks
   - **Executing** - Engineers implement each subtask
   - **Reviewing** - Reviewer validates results
   - **Done** - Final output delivered

All of this happens autonomously from a single message.

## Agents

### Agent Configuration

Agents are JSON files in the agents/ directory:

```json
{
  "id": "software_engineer",
  "name": "Software Engineer",
  "description": "Writes code, runs tests, manages repos",
  "config": {
    "model_id": "gpt-4o",
    "system_prompt": "You are a senior software engineer...",
    "temperature": 0.3
  },
  "tools": ["bash"],
  "skills": ["github.md", "web_dev.md", "debugging.md"]
}
```

Agents without a `tools` field work as simple persona chat (backward-compatible).

### Skills

Skills are markdown files in the skills/ directory, injected into agent system prompts at runtime:

```markdown
<!-- skills/web_research.md -->
# Web Research Best Practices

When searching the web:
1. Use specific, targeted queries
2. Cross-reference multiple sources
3. Verify information currency
4. Document sources in responses
```

### Adding Agents and Skills

You can add agents and skills manually or let the router create them. To add manually:

1. Create `agents/my_agent.json` with the schema above
2. Optionally create skill files in `skills/`
3. Reload with the `/reload` command

## Teams

Teams coordinate multiple agents on complex tasks:

```json
{
  "id": "web_dev",
  "name": "Web Development Team",
  "description": "Full-stack web development team",
  "roles": [
    {
      "agent_id": "project_manager",
      "role": "lead",
      "responsibilities": "Gather requirements and plan architecture"
    },
    {
      "agent_id": "software_engineer",
      "role": "member",
      "responsibilities": "Implement frontend and backend"
    },
    {
      "agent_id": "code_reviewer",
      "role": "reviewer",
      "responsibilities": "Review code for quality and security"
    }
  ],
  "workflow": "PM plans -> Engineer implements -> Reviewer validates"
}
```

Teams created by the router follow the same schema and are hot-reloaded automatically.

## Commands

```
/help              - Show all commands
/start             - Bot introduction

/agents            - List all available agents
/agent <id>        - Switch to specific agent
/auto              - Re-enable auto-routing

/teams             - List available teams
/team <id> <task>  - Start a team task
/task              - Show current task status
/cancel            - Cancel current task

/memory add <text> - Store a memory
/memory search <q> - Search memories
/memory clear      - Delete all memories
/memory stats      - Show memory statistics

/files             - List uploaded files
/sendfile <path>   - Send a file to chat

/history           - Show conversation history
/clear             - Clear conversation
/reload            - Reload agents/teams
```

## MCP Server Integration

Optional external tool servers via Model Context Protocol. Configure in `mcp_servers.json`:

```json
{
  "exa": {
    "command": "npx",
    "args": ["-y", "exa-mcp-server"],
    "env": { "EXA_API_KEY": "..." }
  }
}
```

MCP tools are auto-discovered at startup and registered alongside `bash` in the tool registry. The agent runtime routes tool calls to the appropriate MCP server.

## Memory System

Conversations and memories are persisted to the working directory:

```
workdir/
  memory/
    chat_{id}.json       # Conversation history
    cortex.json          # Memory entries
  workspaces/
    {chat_id}/
      files/             # Uploaded files
      task_{id}/         # Task working directories
```

Relevant memories are automatically injected into context based on TF-IDF similarity scoring.

```
/memory add Meeting with John tomorrow at 3pm #meeting #john
/memory search project requirements
/memory search #meeting
/memory stats
/memory clear
```

## Deployment

### Systemd Service (Production)

```bash
# One-command setup (installs both bot and doctor)
sudo ./install.sh

# Check status
sudo systemctl status sheyybot
sudo journalctl -u sheyybot -f
```

### Health Monitoring (Doctor)

SheyyBot includes an automatic health check system ("Doctor") that monitors the bot and auto-recovers from failures:

- **Process Monitoring** - Detects if the bot crashes or stops responding
- **Memory Limits** - Restarts if memory exceeds 200MB
- **Error Loop Detection** - Detects consecutive poll failures and restarts
- **Telegram API Health** - Monitors API connectivity (informational)

```bash
# Doctor runs automatically every 2 minutes
sudo systemctl status sheyybot-doctor.timer
sudo systemctl list-timers sheyybot-doctor.timer

# View doctor logs
cat /var/log/sheyybot-doctor.log
sudo journalctl -u sheyybot-doctor -f

# Manually trigger a health check
sudo systemctl start sheyybot-doctor.service
```

The doctor is installed automatically by `install.sh` but can also be set up manually:

```bash
# Manual doctor setup
sudo mkdir -p /usr/local/lib/sheyybot
sudo cp scripts/doctor.sh /usr/local/lib/sheyybot/
sudo chmod +x /usr/local/lib/sheyybot/doctor.sh
sudo cp systemd/sheyybot-doctor.service /etc/systemd/system/
sudo cp systemd/sheyybot-doctor.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sheyybot-doctor.timer
```

### Docker (Optional)

```dockerfile
FROM alpine:latest
RUN apk add --no-cache zig
COPY . /app
WORKDIR /app
RUN zig build -Doptimize=ReleaseFast
CMD ["./zig-out/bin/my_zig_agent"]
```

## Testing

```bash
# Run all tests
zig build test

# Run with coverage (requires kcov)
kcov --include-path=./src ./coverage zig build test

# Specific file tests
zig test src/agent.zig
```

## Performance

| Metric | Value |
|--------|-------|
| Binary Size | ~2MB (ReleaseFast) |
| Memory Usage | ~10-50MB runtime |
| Startup Time | <1 second |
| Tool Timeout | 30 seconds |
| Max Tool Iterations | 15 per agent turn |
| Context Window | Configurable (default 50 messages) |

## Troubleshooting

### Service Won't Start

The Doctor will automatically restart the service if it fails, but for manual debugging:

```bash
# Check logs
sudo journalctl -u sheyybot -n 50

# Verify config
sudo cat /var/lib/sheyybot/auth.json
sudo cat /var/lib/sheyybot/models.json

# Check permissions
sudo ls -la /var/lib/sheyybot/
sudo ls -la /usr/local/bin/sheyybot

# Check doctor logs to see if it has been restarting
sudo cat /var/log/sheyybot-doctor.log
sudo journalctl -u sheyybot-doctor -n 20
```

### API Errors

```bash
# Test LLM API
curl -H "Authorization: Bearer YOUR_KEY" \
  https://api.openai.com/v1/models

# Test Telegram API
curl "https://api.telegram.org/botYOUR_TOKEN/getMe"
```

### Memory Issues

```bash
# Check memory usage
sudo systemctl status sheyybot

# View memory stats
sudo journalctl -u sheyybot | grep -i memory

# Clear old memories via /memory clear or delete memory/ directory
```

## Security

- Configuration files have 600 permissions
- Service runs as unprivileged `sheyybot` user
- NoNewPrivileges, PrivateTmp, ProtectSystem enabled
- Allowed users list restricts access
- File uploads limited by size and type

## Architecture Decisions

### Why Zig?

- Explicit memory management (no GC pauses)
- Compile-time computation
- Cross-compilation support
- Small binary size
- C interoperability

### Why Self-Organizing?

- No upfront configuration needed for new domains
- The system adapts to whatever you throw at it
- Agents are created with appropriate tools and skills
- Teams form naturally around project requirements

### Why Telegram?

- Universal availability
- Rich message types
- Bot API simplicity
- Stateless webhooks or polling

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run tests: `zig build test`
4. Commit with clear messages
5. Submit a pull request

## Roadmap

- [x] Multi-agent orchestration with teams
- [x] Autonomous SuperAgent routing
- [x] Self-organizing agent and team creation
- [x] MCP tool server integration
- [x] Streaming responses
- [x] Semantic memory with TF-IDF
- [x] File support
- [x] Systemd service
- [x] Health monitoring with auto-recovery (Doctor)
- [ ] Voice message support
- [ ] Vision model integration
- [ ] Plugin system
- [ ] Web dashboard
- [ ] Multi-tenant support

## License

MIT License - See LICENSE file for details.

## Acknowledgments

- Zig programming language
- Telegram Bot API
- OpenAI API format
- MCP (Model Context Protocol)
- Contributors and testers

---

**Version**: 3.0
**Last Updated**: March 2026
**Status**: Production Ready
