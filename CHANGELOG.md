## 1.1.1

- **Fix always resumes oldest session on startup** — `initialize()` was setting
  `_activeConv = _conversations.first`, which was always the oldest saved
  session. Now a fresh conversation is created as the active one; saved
  sessions remain accessible via `/list` and `/switch`. Use `--load <id>`
  to explicitly resume a past session. (`agent_service.dart`)

- **Fix ACP stdio tool-call reply never returned** — three issues fixed:
  - **HTTP timeout**: `ZenAiService.complete()` now has a 120-second timeout
    on the Zen API POST call, preventing the agent loop from hanging
    indefinitely after tool execution when the AI context is large.
    (`ai_service.dart`)
  - **Preserve AI reasoning before tool calls**: When the AI returns both
    reasoning text and tool calls, the text is now kept in the conversation
    history instead of being discarded with `content: ''`.
    (`agent_service.dart`)
  - **Fallback text for empty AI responses**: If the AI returns no text after
    tool execution, a fallback message is sent so the ACP client (Paseo)
    still receives a visible reply. Errors sending `session/update`
    notifications are now logged to stderr instead of silently swallowed.
    (`agent_service.dart`)

## 1.0.0

- Initial version.

## 1.1.0

- **Session persistence** — conversations auto-save to
  `~/.config/utopic/sessions/<id>.json`. Resume with `/load <id>` or
  `--load <id>` on the CLI. Exit message shows the session ID for rejoining.
- **Fix ACP error propagation** — Zen API errors (e.g. 429 rate limit) are now
  returned to the ACP client as JSON-RPC error responses instead of being
  silently swallowed with an empty success. (`agent_service.dart`)
- Add `--config <path>` CLI flag for explicit config file path.
- Add ACP client support — utopic can connect to remote ACP servers and use
  them as model providers (`/acp-connect`, `/acp-disconnect` commands).
- Add `StdioAcpClient` — spawn a local CLI subprocess as an ACP provider
  (`/acp-connect cli:<command>`).
- Refactor `AcpClient` to abstract class with `TcpAcpClient` and
  `StdioAcpClient` implementations sharing a `_PendingManager` for
  JSON-RPC message handling.
- Refactor `AiService` to abstract class with `ZenAiService` and `AcpAiService`
  implementations.
- Add `AcpClient` class for JSON-RPC 2.0 over TCP client connections.
- Add `acp.clients` config for auto-connect on startup.
- Add AcpClient and StdioAcpClient test suites (57 tests passing).
