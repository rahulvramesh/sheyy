# SheyyBot v2.0 - Highly Intelligent Multi-Agent System

A sophisticated multi-agent orchestration system built as a Telegram bot in Zig 0.14+. Features autonomous routing, advanced reasoning, self-reflection, and team collaboration capabilities.

## Overview

SheyyBot is not just a simple Telegram-LLM bridge—it's a complete multi-agent platform with:

- 🤖 **9 Specialized Agents** - Each with unique capabilities and tools
- 🧠 **Chain-of-Thought Reasoning** - Step-by-step problem solving
- 🔄 **Self-Reflection & Learning** - Improves from experience
- ⚡ **Parallel Tool Execution** - Run multiple tools simultaneously
- 📡 **Streaming Responses** - Real-time token streaming
- 🧬 **Semantic Memory** - TF-IDF based intelligent retrieval
- 🌐 **Web Fetch Tool** - Native HTTP client for research
- 📁 **File & Image Support** - Upload and download capabilities
- 🔧 **Systemd Service** - Production-ready deployment

## Architecture

```
Layer 4: Application
├── main.zig              - Entry point, message routing
├── router.zig            - Autonomous message routing (Super Agent)
└── memory_cortex.zig     - Persistent memory with semantic search

Layer 3: Team & Orchestration
├── orchestrator.zig      - Multi-agent task coordination
└── team.zig              - Team definitions and role management

Layer 2: Agent Runtime
├── agent.zig             - Agent execution with CoT & reflection
└── conversation.zig      - Message history persistence

Layer 1: Tool System
├── tools.zig             - Tool registry (bash, fetch)
└── mcp.zig               - MCP client for external tools

Layer 0: Infrastructure
├── config.zig            - Configuration management
├── telegram.zig          - Telegram Bot API client
└── llm.zig               - LLM API client with retry logic
```

## Quick Start

### Prerequisites

- Zig 0.14.0 or later
- Telegram Bot Token (from @BotFather)
- OpenAI-compatible LLM API key

### Installation

```bash
# Clone the repository
git clone https://github.com/rahulvramesh/sheyy.git
cd sheyy

# Build the project
zig build -Doptimize=ReleaseFast

# Configure
# Edit auth.json and models.json with your credentials

# Run
zig build run
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

## Deployment

### Systemd Service (Production)

```bash
# One-command setup
sudo ./scripts/setup-service.sh
sudo ./scripts/deploy.sh

# Check status
sudo systemctl status sheyybot
sudo journalctl -u sheyybot -f
```

### Docker (Optional)

```dockerfile
# Dockerfile
FROM alpine:latest
RUN apk add --no-cache zig
COPY . /app
WORKDIR /app
RUN zig build -Doptimize=ReleaseFast
CMD ["./zig-out/bin/my_zig_agent"]
```

## Agents

### Available Agents

| Agent | Description | Tools | Skills |
|-------|-------------|-------|--------|
| **assistant** | General purpose assistant | bash | reasoning, web_search |
| **software_engineer** | Code development expert | bash | debugging, reasoning, web_dev, github, web_search |
| **code_architect** | System design specialist | bash | system_design, reasoning, debugging |
| **debug_expert** | Debugging specialist | bash | debugging, reasoning, web_search |
| **research_assistant** | Web research expert | bash, fetch | web_research, web_search |
| **project_manager** | Task planning & coordination | bash | system_design, reasoning |
| **code_reviewer** | Code review specialist | bash | debugging, reasoning, web_search |
| **coder** | Quick code assistant | bash | debugging, reasoning |
| **creative** | Creative writing | bash | reasoning, web_search |

### Agent Configuration

Agents are defined in JSON files:

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
  "tools": ["bash", "fetch"],
  "skills": ["github.md", "web_dev.md", "debugging.md"],
  "enable_reasoning": true,
  "enable_reflection": true
}
```

### Skills

Skills are markdown files injected into agent prompts:

```markdown
<!-- skills/web_research.md -->
# Web Research Best Practices

When searching the web:
1. Use specific, targeted queries
2. Cross-reference multiple sources
3. Verify information currency
4. Document sources in responses
```

## Commands

### User Commands

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

## Advanced Features

### Chain-of-Thought Reasoning

Enable step-by-step reasoning for complex problems:

```zig
agent_runtime.enableCoT(.zero_shot);
// or .few_shot with examples
// or .self_consistency for multiple reasoning paths
```

The agent will show its reasoning process:
```
Step 1: Observing that...
Step 2: Thinking about...
Step 3: Taking action...
Final Answer: ...
```

### Self-Reflection & Learning

Agents automatically reflect on completed tasks:

```zig
agent_runtime.enable_reflection = true;
agent_runtime.min_reflection_confidence = 0.7;
```

Reflections are stored with `#reflection` tag and automatically retrieved for similar future tasks.

### Semantic Memory Search

Find memories by meaning, not just keywords:

```zig
const results = cortex.searchSemantic("authentication bug", 5, 0.6);
// Returns memories sorted by TF-IDF cosine similarity
```

### Parallel Tool Execution

Execute independent tools simultaneously:

```zig
// Tools that don't depend on each other run in parallel
const results = try agent_runtime.executeToolsParallel(calls, 5);
// Up to 5 tools concurrently, maintaining result order
```

### Streaming Responses

Real-time token streaming for better UX:

```json
// models.json
{
  "enable_streaming": true
}
```

Responses appear word-by-word instead of waiting for full completion.

### Retry Logic

Automatic retry with exponential backoff:

- Retries on: timeouts, rate limits, 5xx errors
- Delays: 1s, 2s, 4s, 8s (with ±25% jitter)
- Max 3 retries before failure

### File Support

Upload files to the bot:
- Photos up to 20MB
- Documents up to 50MB
- Files saved to `workspaces/{chat_id}/files/`
- Agents can reference files in bash commands

## Teams

Define multi-agent teams for complex tasks:

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
  "workflow": "PM plans → Engineer implements → Reviewer validates"
}
```

## Memory System

### Storage

Conversations and memories are persisted to:
```
/var/lib/sheyybot/
├── memory/
│   ├── chat_{id}.json       # Conversation history
│   └── cortex.json          # Memory entries
└── workspaces/
    └── {chat_id}/
        ├── files/           # Uploaded files
        └── task_{id}/       # Task working directories
```

### Memory Commands

```
/memory add Meeting with John tomorrow at 3pm #meeting #john
/memory search project requirements
/memory search #meeting
/memory stats
/memory clear
```

### Auto-Retrieval

Relevant memories are automatically injected into context based on TF-IDF similarity scoring.

## Testing

```bash
# Run all tests
zig build test

# Run with coverage (requires kcov)
kcov --include-path=./src ./coverage zig build test

# Specific file tests
zig test src/agent.zig
zig test src/memory_cortex.zig
```

### Test Coverage

- **138 tests** across all modules
- Unit tests for each source file
- Integration tests for orchestration
- Error case coverage
- Mock-based testing for external APIs

## CI/CD

GitHub Actions workflows:

```yaml
# .github/workflows/ci.yml
- Run on every push/PR
- Test with Zig 0.14.0
- Build release binary
- Check formatting

# .github/workflows/release.yml
- Trigger on v* tags
- Create GitHub release
- Attach binary artifacts
```

## Performance

| Metric | Value |
|--------|-------|
| Binary Size | ~2MB (ReleaseFast) |
| Memory Usage | ~10-50MB runtime |
| Startup Time | <1 second |
| Tool Timeout | 30 seconds |
| Max Tool Iterations | 15 |
| Parallel Tools | Up to 5 concurrent |
| Context Window | Configurable (default 50 messages) |

## Troubleshooting

### Service Won't Start

```bash
# Check logs
sudo journalctl -u sheyybot -n 50

# Verify config
sudo cat /var/lib/sheyybot/auth.json
sudo cat /var/lib/sheyybot/models.json

# Check permissions
sudo ls -la /var/lib/sheyybot/
sudo ls -la /usr/local/bin/sheyybot
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

# Clear old memories
# Use /memory clear command or delete /var/lib/sheyybot/memory/
```

## Development

### Adding a New Tool

1. Define tool in `src/tools.zig`:
```zig
pub const MyTool = struct {
    pub const SCHEMA = "...";
    pub fn execute(allocator, args) !ToolResult { ... }
};
```

2. Register in `ToolRegistry`

3. Add to agent's `tools` array in JSON

### Adding a New Agent

1. Create `agents/my_agent.json`
2. Define tools and skills
3. Reload with `/reload` command

### Adding a New Skill

1. Create `skills/my_skill.md`
2. Write skill documentation
3. Reference in agent's `skill_names`

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

### Why Multi-Agent?

- Specialization beats generalization
- Parallel execution of subtasks
- Better context management
- Clear responsibility boundaries

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

- [x] Chain-of-Thought reasoning
- [x] Self-reflection & learning
- [x] Parallel tool execution
- [x] Streaming responses
- [x] Semantic memory
- [x] File support
- [x] Systemd service
- [ ] Voice message support
- [ ] Vision model integration
- [ ] Plugin system
- [ ] Web dashboard
- [ ] Multi-tenant support

## License

MIT License - See LICENSE file for details

## Acknowledgments

- Zig programming language
- Telegram Bot API
- OpenAI API format
- MCP (Model Context Protocol)
- Contributors and testers

---

**Version**: 2.0  
**Last Updated**: March 2026  
**Status**: Production Ready ✅
