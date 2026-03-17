# My Zig Agent

A minimal Telegram-LLM bridge application written in idiomatic Zig (v0.14+). This bot polls Telegram for messages, forwards them to an OpenAI-compatible LLM API, and returns the responses to users.

## Project Structure

```
my_zig_agent/
├── build.zig           # Zig build configuration
├── build.zig.zon       # Package manifest
├── src/
│   ├── main.zig        # Entry point and orchestration loop
│   ├── config.zig      # JSON parsing for auth and model configs
│   ├── telegram.zig    # Telegram Bot API client
│   └── llm.zig         # OpenAI-compatible LLM API client
├── auth.json           # Telegram token and LLM API key
└── models.json         # LLM endpoint and model configuration
```

## Configuration

### auth.json
```json
{
  "telegram_bot_token": "YOUR_TELEGRAM_BOT_TOKEN",
  "llm_api_key": "YOUR_LLM_API_KEY"
}
```

### models.json
```json
{
  "llm_endpoint_url": "https://api.openai.com/v1/chat/completions",
  "model_name": "gpt-4o-mini"
}
```

## Building

```bash
# Build the application
zig build

# Build in release mode
zig build -Doptimize=ReleaseFast

# Run the application
zig build run
```

## Testing

```bash
# Run all unit tests
zig build test
```

The test suite includes:
- JSON parsing tests for configuration files
- Telegram update parsing tests
- LLM response parsing tests
- Request payload construction tests

## Running

1. Configure your `auth.json` with your Telegram Bot Token (from @BotFather) and your LLM API key
2. Configure `models.json` with your preferred endpoint and model
3. Run: `zig build run`

The bot will:
1. Load configuration files
2. Connect to Telegram's API using long-polling
3. For each incoming message, send it to the configured LLM
4. Return the LLM's response to the user

## Deployment as System Service

For production deployments, you can run SheyyBot as a systemd service:

### Quick Setup

```bash
# Run the setup script (requires root)
sudo ./scripts/setup-service.sh

# Deploy your configuration and start the service
sudo ./scripts/deploy.sh
```

### Manual Setup

1. **Build the project:**
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

2. **Create system user:**
   ```bash
   sudo useradd --system --no-create-home --shell /bin/false sheyybot
   ```

3. **Install binary:**
   ```bash
   sudo cp zig-out/bin/my_zig_agent /usr/local/bin/sheyybot
   sudo chmod 755 /usr/local/bin/sheyybot
   ```

4. **Create working directory:**
   ```bash
   sudo mkdir -p /var/lib/sheyybot
   sudo mkdir -p /var/lib/sheyybot/{agents,teams,skills,memory,workspaces}
   sudo chown -R sheyybot:sheyybot /var/lib/sheyybot
   ```

5. **Copy configuration:**
   ```bash
   sudo cp auth.json models.json allowed_users.json /var/lib/sheyybot/
   sudo cp -r agents teams skills /var/lib/sheyybot/
   sudo chown -R sheyybot:sheyybot /var/lib/sheyybot
   ```

6. **Install systemd service:**
   ```bash
   sudo cp systemd/sheyybot.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable sheyybot
   sudo systemctl start sheyybot
   ```

### Service Management

```bash
# Check status
sudo systemctl status sheyybot

# View logs
sudo journalctl -u sheyybot -f

# Restart service
sudo systemctl restart sheyybot

# Stop service
sudo systemctl stop sheyybot

# Update configuration and restart
sudo ./scripts/deploy.sh
```

### File Locations

| Component | Location |
|-----------|----------|
| Binary | `/usr/local/bin/sheyybot` |
| Working directory | `/var/lib/sheyybot` |
| Config files | `/var/lib/sheyybot/*.json` |
| Agents | `/var/lib/sheyybot/agents/` |
| Teams | `/var/lib/sheyybot/teams/` |
| Skills | `/var/lib/sheyybot/skills/` |
| Memory | `/var/lib/sheyybot/memory/` |
| Workspaces | `/var/lib/sheyybot/workspaces/` |
| Logs | `journalctl -u sheyybot` |

## Memory Management

This application uses Zig's explicit memory management with:
- General Purpose Allocator (GPA) for leak detection in debug builds
- Proper cleanup with `defer` and `errdefer`
- No memory leaks under normal operation

## Error Handling

All errors are properly propagated and logged:
- Configuration file errors (missing, malformed JSON)
- HTTP request failures
- API response parsing errors
- Network timeouts

## Compatibility

- **Zig Version**: 0.14.0 or later
- **API**: OpenAI-compatible chat completions API
- **Telegram**: Bot API via HTTPS

## License

MIT License - See LICENSE file for details
