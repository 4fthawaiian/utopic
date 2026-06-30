# Utopic — Agent Context

## Project Overview

Utopic is a queer-coded AI coding agent designed as a **Paseo-first backend**.
It runs in the terminal, talks to AI models via the OpenCode Zen API or
OpenRouter, and serves as an ACP stdio server for **Paseo** (the primary
UI/UX). Utopic also has its own TUI for standalone use, but **all new features
must work equally or better over ACP stdio** before being polished for the TUI.

## Paseo-First Development

⚠️ **All new features must work over ACP stdio before the TUI.**

Paseo connects to Utopic via `--acp-stdio` (stdin/stdout JSON-RPC 2.0). This is
the primary user-facing path. The TUI is a secondary interface for power users.

### ACP stdio testing checklist

When adding a new feature, verify it works through Paseo:

1. **Slash commands** — `/models`, `/model`, `/provider`, `/help`, `/config`
   are handled in `onPrompt()` in `agent_service.dart` and stream responses as
   `AgentMessageChunkSessionUpdate` session updates. This was added so Paseo
   sees command output in the conversation instead of getting empty responses.

2. **Model lists** — `onNewSession()` sends ALL models (Zen + OpenRouter + LM
   Studio, deduplicated) in the `models` field so Paseo shows them in its
   model selector dropdown.

3. **Provider switching** — `/provider <zen|openrouter|lmstudio>` works over
   ACP stdio the same as in TUI. Test with:
   `printf '.../prompt.../provider lmstudio...'`
   The response streams back as session updates.

4. **Model auto-switch** — `/model openai/gpt-4o` (an OpenRouter model) should
   auto-switch the provider to OpenRouter and report it in the response.

5. **Tool progress** — Tool calls are streamed as `ToolCallSessionUpdate` /
   `ToolCallUpdateSessionUpdate` so Paseo shows real-time progress. Text
   reasoning before tool calls is sent as `AgentMessageChunkSessionUpdate`.

6. **Context tracking** — Usage updates (`UsageUpdate`) are sent after each
   round so Paseo shows the context window usage bar.

5. **Session load/resume** — `session/load` and `session/resume` are
   implemented in `acp_agent.dart` and `agent_service.dart`. Load streams
   full conversation history as `session/update` notifications (message
   chunks, tool calls, usage updates). Resume restores session state without
   replaying history. Both use `_acpSessionToConvId` to map ACP session IDs
   to internal conversation IDs. **Both send a `UsageUpdate`** so Paseo
   shows the context bar immediately on load/resume.

6. **Cross-restart session persistence** — Conversations are auto-saved to
   `~/.config/utopic/sessions/<id>.json` after every exchange (including
   slash commands). On startup, `initialize()` rebuilds the
   `_acpSessionToConvId` mapping from saved sessions, so `session/resume`
   works even after a full process restart.

7. **No TUI assumption** — The `AgentService` core (`agent_service.dart`) must
   never assume a TUI is attached. All UI updates go through streams
   (`conversationsStream`, `activeConversationStream`) that the TUI subscribes
   to. ACP mode works without any of those streams being consumed.

### When adding a feature

```
1. Implement in agent_service.dart (ACP path)  ← always first
2. Test with Paseo: utopic --acp-stdio
3. Add TUI surface in utopic_tui.dart            ← secondary
4. Update help text in both files
```

## Current Architecture (`main`)

```
bin/utopic.dart            — Entry point: arg parsing → one-shot or TUI mode
lib/
├── utopic.dart            — Barrel exports
└── src/
    ├── acp/               — Agent Client Protocol (via acp_dart package)
    │   ├── acp.dart                 — Barrel
    │   ├── acp_types.dart           — Protocol type definitions
    │   ├── acp_dart_client.dart     — TCP + stdio clients (utopic connects TO other agents)
    │   ├── acp_server.dart          — TCP/stdio server (other agents connect TO utopic)
    │   └── acp_agent.dart           — AcpAgent: Agent interface implementation
    ├── config/            — YAML/env config loading
    │   └── app_config.dart
    ├── models/            — Data models
    │   ├── conversation.dart        — Conversation + Message
    │   └── zen_models.dart          — Zen, OpenRouter & LM Studio model catalog
    ├── services/          — Core services
    │   ├── ai_service.dart          — AiService (abstract), ZenAiService, OpenRouterAiService, LmStudioAiService, AcpAiService
    │   ├── agent_service.dart       — Agent loop, provider switching, conversation mgmt, ACP lifecycle
    │   ├── skills.dart              — Agent Skills spec loader
    │   ├── session_store.dart       — Session persistence (save/load convos)
    │   └── tools/                   — Tool implementations
    │       ├── tool.dart            — Base tool class (Responses API + Chat Completions API formats)
    │       ├── tools.dart           — Tool registry
    │       ├── bash_tool.dart
    │       ├── read_tool.dart
    │       ├── write_tool.dart
    │       └── edit_tool.dart
    ├── tui/               — TUI app
    │   └── utopic_tui.dart          — UtopicTuiApp (build + events + commands)
    └── vendor/            — Vendored/patched code
        └── runner.dart              — Vendored utopia_tui runner (Ctrl+D exit)
```

## ACP Implementation

Utopic uses the [`acp_dart`](https://pub.dev/packages/acp_dart) package for
both client and server ACP communication.

### ACP Client (connect to remote agents)

- **`AcpClient`** (in `acp_dart_client.dart`) — connects to remote ACP servers
  over TCP or local subprocess (stdio)
- **`AcpAiService`** (in `ai_service.dart`) — wraps an `AcpClient`, implements
  `AiService.complete()` by forwarding prompts to the remote agent
- Models are discovered from `NewSessionResponse.configOptions`

### ACP Server (be a backend for other tools)

- **`AcpAgent`** (in `acp_agent.dart`) — implements `acp_dart`'s `Agent`
  interface, delegates to `AgentService` via `AcpAgentDelegate`
- **`AcpServer`** (in `acp_server.dart`) — thin transport wrapper (TCP/stdio)
  over `AgentSideConnection`
- Supports standard ACP methods: `session/new`, `session/prompt`,
  `session/cancel`, `session/list`, `session/load`, `session/resume`,
  `session/set_model`, `session/set_mode`, `session/set_config_option`,
  `fs/read_text_file`, `fs/write_text_file`, `terminal/create`, etc.
- **Session load** streams full conversation history as `session/update`
  notifications (message chunks, tool calls, tool results, usage updates)
  so Paseo can populate the chat view.
- **Session resume** restores session state from disk or in-memory without
  replaying history — uses `_acpSessionToConvId` mapping to find the
  conversation by session ID.
- **`_restart` extension notification** — Paseo can send this to reset all
  agent state (clear conversations, cancel in-flight work, reinitialize)
  without killing the subprocess. Handled in `extNotification()`.
- **Re-initialization** — a second `initialize` call triggers `onRestart()`
  (same as `_restart`), so reconnecting from Paseo starts fresh.
- Headless modes: `--acp-server` (TCP), `--acp-stdio` (stdin/stdout)

## Agent Loop (`agent_service.dart`)

The `_runAgentLoop` method:
1. Calls `ai.complete()` with the conversation + tools
2. If result has tool calls → executes tools → adds results → loops (max 10)
3. If result has text → adds assistant message → returns

Cancellation via the `_cancelRequested` flag:
- Checked before each `ai.complete()` call
- Checked after each `ai.complete()` returns
- Checked before each tool execution
- **HTTP abort** — `cancel()` also calls `ai.cancel()` which closes the
  underlying HTTP client, immediately aborting any in-flight request. The
  caught exception is treated as clean cancellation.
- Cancellation messages are streamed as `AgentMessageChunkSessionUpdate`
  so Paseo sees "🛑 Cancelled." instead of an empty response.

## Session Persistence

Conversations auto-save to `~/.config/utopic/sessions/<id>.json` after every
exchange (including slash commands like `/model`, `/provider`).

### ACP session/load and session/resume

- **`session/load`** — restores a conversation from disk and streams the
  full history back as `session/update` notifications (message chunks, tool
  calls, usage updates) so Paseo can populate its chat view.
- **`session/resume`** — restores session state without replaying history.
  Uses `_acpSessionToConvId` to find the conversation by ACP session ID
  (checking in-memory first, falling back to disk).
- **Cross-restart** — on startup, `initialize()` rebuilds the
  `_acpSessionToConvId` mapping from saved sessions, so `session/resume`
  works even after a full process restart.
- **ACP session ID as conversation ID** — conversations created via ACP use
  the ACP session ID (e.g. `session_123...`) directly as their conversation
  ID, ensuring the file on disk matches what Paseo sends in load/resume.

Save/load via `/save`, `/load <id>`, or `--load <id>` on CLI.

## Building & Testing

```bash
dart pub get
dart compile exe bin/utopic.dart -o utopic
dart test                          # 6 tests
dart analyze                       # 0 errors/warnings expected
```

### Testing via ACP stdio (Paseo)

To manually test a feature over ACP stdio (simulating what Paseo sends):

```bash
# Start utopic in ACP stdio mode, then send JSON-RPC from another terminal
echo '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"'$PWD'"}}' \
  | ./utopic --acp-stdio 2>/dev/null

# Or chain a command right after session/new:
printf '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"'$PWD'"}}\n{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"test","prompt":"/models"}}\n' \
  | ./utopic --acp-stdio 2>/dev/null
```

For real Paseo testing, add this to your Paseo config's `agents` section:
```json
{
  "command": "utopic",
  "args": ["--acp-stdio"],
  "cwd": "/path/to/your/project"
}
```

## Configuration

Utopic loads configuration from YAML files (see README for load order). Key fields:

| Field | Default | Description |
|-------|---------|-------------|
| `opencode_api_key` | env `OPENCODE_API_KEY` | OpenCode Zen API key |
| `default_model` | `deepseek-v4-flash-free` | Zen model to use on startup |
| `zen_endpoint` | `https://opencode.ai/zen` | Zen API endpoint |
| `provider` | `zen` | Default AI provider (`zen`, `openrouter`, or `lmstudio`) |
| `openrouter_api_key` | env `OPENROUTER_API_KEY` | OpenRouter API key |
| `openrouter_endpoint` | `https://openrouter.ai/api/v1` | OpenRouter API endpoint |
| `default_openrouter_model` | `openai/gpt-4o` | Default model when using OpenRouter |
| `lm_studio_endpoint` | `http://localhost:1234/v1` | LM Studio API endpoint |
| `default_lm_studio_model` | `local-model` | Default model when using LM Studio |
| `max_iterations` | `10` | Max AI + tool-call rounds before stopping (prevents runaway loops) |
| `system_prompt` | (hardcoded) | Override the default system prompt |
| `acp.enabled` | `false` | Auto-start ACP server on boot |
| `acp.host` | `127.0.0.1` | ACP server bind address |
| `acp.port` | `8080` | ACP server port |

## Key Gotchas

### Dart AOT stdout bug

**Dart 3.12.1** has a compiler bug: in AOT-compiled executables, calling
`stdin.listen()` on a TTY stdin can corrupt the Stdout IOSink. The vendored
runner uses `TuiTerminal.write()` (from `utopia_tui`) which sidesteps this
in most cases. If adding new output paths that run after `stdin.listen()`,
write through `TuiTerminal.write()` or write directly to `/dev/stdout`.

### TUI Scroll Viewport

Inside `TuiPanelBox(padding: 1)`, the actual scrollable viewport is
`h - 7 - inputLineCount` wide and `w - 4` tall (border 2 + padding 2 +
status bar 1 + hint bar 1 + input area). Use `_viewportHeight(context)` and
`_viewportWidth(context)` helpers instead of raw `context.height - 4`.

**Gotcha**: if you add/remove UI rows (status bar, hints, input area
height), you must update the helper formulas in `utopic_tui.dart`.

### ACP stdio: session/new params format

The `acp_dart` package expects `session/new` params as a map with `cwd` and
optionally `configOptions`. If you hand-craft JSON-RPC to test, make sure the
params are wrapped as an object, not passed directly. Example:

```json
{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp"}}
```

### Paseo expects session/prompt to always return

After every `session/prompt`, Paseo expects a response — even for slash
commands. If `onPrompt()` handles a `/command` without returning actual result
data, Paseo may show a blank response. The fix (already implemented) is to
stream the command output as `AgentMessageChunkSessionUpdate` and return
`{inputTokens: 0, outputTokens: 0}`.

### ACP session/resume requires ID mapping

`session/resume` relies on `_acpSessionToConvId` to find conversations. This
mapping is populated in three places:
1. `onNewSession()` — registers the ACP session ID → conversation ID mapping
2. `initialize()` — rebuilds from saved sessions on disk (critical for
   cross-restart resume)
3. `onResumeSession()` / `onLoadSession()` — re-registers on each access

**Gotcha**: if you add a new code path that creates conversations, make sure
to register the mapping. Sessions created outside ACP (e.g. via `/new` in the
TUI) use `conv_xxx` IDs that won't match ACP session IDs — `onPrompt()` falls
back to finding them by `sessionId` directly, but `session/resume` won't work
unless the mapping exists.

### HTTP client cancellation pattern

`AiService.cancel()` closes the underlying HTTP client to abort in-flight
requests, then creates a fresh client. This is implemented in all providers:
`ZenAiService`, `OpenRouterAiService`, `LmStudioAiService`, and
`AcpAiService`.

The agent loop wraps `ai.complete()` in try/catch — if cancellation closes
the client mid-request, the caught exception is treated as clean cancellation
rather than an error. This means `Ctrl+C` in Paseo stops the agent
**immediately** instead of waiting for the HTTP request to finish.

### Provider switching (Zen ↔ OpenRouter ↔ LM Studio)

`AgentService` supports switching between `ZenAiService`, `OpenRouterAiService`,
and `LmStudioAiService` at runtime via `/provider <zen|openrouter|lmstudio>`
or automatically when `/model <id>` selects a model from another provider.

The switching logic:
1. If the current AI service matches the target provider, do nothing.
2. Save the old service as a "fallback" (`_zenFallback` / `_openrouterFallback` / `_lmStudioFallback`)
3. Restore or create the new provider's service
4. Fetch models if it's a new service

This means provider switching is near-instant after the first fetch.
The fallback references allow returning to the original provider without
re-fetching models.

### Pride Theming

Rainbow gradient in status bar, cycling message headers. Toggle with
`/phobe` or `--phobe` (which also replaces the queer welcome message
with a neutral one).

## Coding Conventions

- **Imports:** Prefer package imports (`package:utopic/...`) over relative
  inside `bin/`, relative (`../...`) inside `lib/`.
- **State:** No state management library — plain Dart objects, streams for
  UI updates (`conversationsStream`, `activeConversationStream`).
- **ACP JSON-RPC:** Uses `acp_dart`'s typed `ClientSideConnection` /
  `AgentSideConnection` — no manual JSON-RPC framing.
- **Error handling:** Agent loop errors caught and reported in TUI status bar.
- **Tools:** Each tool extends `Tool` base class with `name` and
  `execute(Map<String, dynamic> args)`. Tool definitions are
  JSON-serialisable maps.
