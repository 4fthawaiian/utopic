# Utopic — Agent Context

## Project Overview

Utopic is a queer-coded TUI AI coding agent. It runs in the terminal, talks to
AI models via the OpenCode Zen API or the Agent Client Protocol (ACP), and has
full tool access (bash, read, write, edit) for autonomous code work.

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
    │   └── zen_models.dart          — Zen API model catalog
    ├── services/          — Core services
    │   ├── ai_service.dart          — AiService (abstract), ZenAiService, AcpAiService
    │   ├── agent_service.dart       — Agent loop, conversation management, ACP lifecycle
    │   ├── skills.dart              — Agent Skills spec loader
    │   ├── session_store.dart       — Session persistence (save/load convos)
    │   └── tools/                   — Tool implementations
    │       ├── tool.dart            — Base tool class
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
  `session/cancel`, `session/list`, `fs/read_text_file`, `fs/write_text_file`,
  `terminal/create`, etc.
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

## Session Persistence

Conversations auto-save to `~/.config/utopic/sessions/<id>.json` after every
exchange. Save/load via `/save`, `/load <id>`, or `--load <id>` on CLI.

## Building & Testing

```bash
dart pub get
dart compile exe bin/utopic.dart -o utopic
dart test                          # 57 tests
dart analyze                       # 0 errors/warnings expected
```

## Configuration

Utopic loads configuration from YAML files (see README for load order). Key fields:

| Field | Default | Description |
|-------|---------|-------------|
| `opencode_api_key` | env `OPENCODE_API_KEY` | OpenCode Zen API key |
| `default_model` | `deepseek-v4-flash-free` | Model to use on startup |
| `zen_endpoint` | `https://opencode.ai/zen` | Zen API endpoint |
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
