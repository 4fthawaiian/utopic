# Connecting Paseo to Utopic via ACP (Stdio Mode)

Paseo communicates with utopic over **ACP stdio** — utopic is spawned as a
subprocess and talks JSON-RPC 2.0 over stdin/stdout. No network port needed.

## Step 1: Build (or use the binary)

```bash
dart compile exe bin/utopic.dart -o utopic
```

Or run directly:

```bash
dart run -- --acp-stdio
```

## Step 2: Configure Paseo

Tell Paseo to spawn utopic in ACP stdio mode:

```json
{
  "acp": {
    "enabled": true,
    "command": "dart run -- --acp-stdio",
    "timeout": 120,
    "retryAttempts": 3,
    "retryDelay": 1000
  }
}
```

If you compiled a binary:

```json
{
  "acp": {
    "enabled": true,
    "command": "./utopic --acp-stdio",
    "timeout": 120,
    "retryAttempts": 3,
    "retryDelay": 1000
  }
}
```

Save this as your paseo configuration file (typically `paseo.yaml` or
`paseo_config.json`).

### What happens

When Paseo starts, it:

1. Spawns `dart run -- --acp-stdio` (or your binary) as a subprocess
2. Sends JSON-RPC 2.0 messages to utopic's **stdin**
3. Reads JSON-RPC 2.0 responses from utopic's **stdout**
4. Communicates over ACP methods: `initialize`, `session/new`,
   `session/prompt`, etc.

No network ports are opened — everything goes through the pipe.

## Step 3: Verify

Run utopic in stdio mode manually to check it responds:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' | dart run -- --acp-stdio
```

Expected output (single line of JSON):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "server_name": "utopic-agent",
    "server_version": "1.0.0",
    "agent_info": { "name": "utopic-agent", "version": "1.0.0" }
  }
}
```

(A full session/prompt test requires a multi-step exchange — use Paseo for that.)

## What Paseo Sees Over ACP

When you send a prompt to Utopic via ACP, it streams back **session updates**
that Paseo renders as a rich timeline:

| Update Type | What Paseo Shows |
|---|---|
| `AgentThoughtChunkSessionUpdate` | **Thinking indicators** — "Analyzing your request", "Processing results (round 2/10)" |
| `AgentMessageChunkSessionUpdate` | **Assistant text** — AI reasoning, commentary, and final responses |
| `ToolCallSessionUpdate` | **Tool call cards** — read, write, edit, bash with file paths and status |
| `ToolCallUpdateSessionUpdate` | **Tool results** — output previews (truncated at 500 chars) |
| `UsageUpdate` | **Token usage bar** — context window percentage + cumulative tokens |

This means Paseo shows:
- ✨ A smooth **thinking → reasoning → tool calls → result** flow
- 🧠 The AI's commentary **before** tool calls as actual text (not hidden in thoughts)
- 🔧 Tool calls with their file paths, status, and result previews
- 📊 A token usage bar that grows across multiple rounds

No extra configuration needed — it just works! 💖

## Troubleshooting

- **No response / empty output**: Make sure you're sending newline-delimited
  JSON. Each message must end with `\n`.
- **Binary not found**: Use the full path to `utopic` in the `command` field.
- **Timeout**: Agent loops can take a while. Increase `timeout` (in seconds)
  in the Paseo config.
- **ACP parse errors**: Check that your Paseo version supports the
  `command` field for subprocess ACP connections.

## Notes

- Stdio mode communicates exclusively over stdin/stdout — stderr is used
  for server-side diagnostics and is ignored by the ACP protocol
- Both `\n` and `\r\n` line endings are accepted
- The server supports both integer and string JSON-RPC 2.0 IDs
- If you prefer TCP mode instead (e.g. for `nc`-based testing), use
  `--acp-server` instead:
  ```bash
  dart run -- --acp-server
  # Listens on tcp://127.0.0.1:8080
  ```

For more information about utopic's ACP implementation, see:
- `lib/src/acp/acp_server.dart`
- `lib/src/acp/acp_agent.dart`
- `lib/src/services/agent_service.dart`
