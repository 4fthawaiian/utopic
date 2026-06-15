# Connecting Paseo to Utopic ACP Server

## Step 1: Start Utopic ACP Server

Run utopic in daemon mode (TCP):
```bash
dart run -- --acp-server
```

Or for stdio mode (for subprocess-based tools like Paseo):
```bash
dart run -- --acp-stdio
```

Or if compiled:
```bash
./utopic --acp-server
./utopic --acp-stdio
```

You should see:
```
ACP server started on 127.0.0.1:8080
Press Ctrl+C to stop server...
```

## Step 2: Configure Paseo

Use the following configuration for paseo (adjust host/port if needed):

```json
{
  "acp": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 8080,
    "timeout": 30,
    "retryAttempts": 3,
    "retryDelay": 1000
  }
}
```

Save this as your paseo configuration file (typically `paseo.yaml` or similar).

## Step 3: Verify Connection

Test the connection manually:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | nc localhost 8080
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "server_name": "utopic-agent",
    "server_version": "1.0.0",
    "capabilities": [
      "initialize",
      "session/prompt",
      "session/cancel",
      "session/new",
      "session/list",
      "session/delete",
      "session/load",
      "session/set_config_option",
      "session/set_model",
      "session/set_mode",
      "fs/read_text_file",
      "fs/write_text_file",
      "fs/list",
      "terminal/create",
      "terminal/kill",
      "terminal/output",
      "terminal/release",
      "terminal/wait_for_exit"
    ],
    "agent_info": {
      "model": "<current-model>",
      "provider": "<provider>"
    }
  }
}
```

## Troubleshooting

- **Connection refused**: Make sure the utopic ACP server is running (`./bin/utopic --acp-server`)
- **Timeout**: Verify paseo is connecting to the correct host and port
- **No response**: Check that paseo is sending properly formatted JSON-RPC 2.0 messages with newline delimiters

## Notes

- The server handles both `\n` and `\r\n` line endings
- Supports both integer and string IDs per JSON-RPC 2.0 specification
- Includes a 5-minute timeout on handler execution to prevent indefinite hangs
- All standard ACP methods are implemented: initialize, session/*, session/prompt, filesystem operations, terminal commands
- Stdio mode (`--acp-stdio`) communicates over stdin/stdout for subprocess-based integrations

For more information about utopic's ACP implementation, see:
- `lib/src/acp/acp_server.dart`
- `lib/src/acp/acp_agent.dart`
- `lib/src/acp/acp_dart_client.dart`
- `lib/src/services/agent_service.dart`