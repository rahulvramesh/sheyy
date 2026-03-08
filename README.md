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
