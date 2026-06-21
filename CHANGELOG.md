## 1.1.3

- **Fix TUI replies not visible — scroll viewport dimensions were wrong**
  - `_scrollToBottom`, arrow up/down, PgUp/PgDn, End, and model selector all
    used `context.height - 4` as the viewport height. But inside
    `TuiPanelBox(padding: 1)`, the actual scrollable area is much smaller:
    `h - 7 - inputLineCount` (border 2 + padding 2 + status bar 1 + hint bar 1
    + input area). The entire last 4+ lines of the conversation were always
    clipped off-screen, so AI replies (and any new content) were invisible.
  - Fixed: added `_viewportHeight(context)` and `_viewportWidth(context)`
    helpers that compute the actual inner viewport dimensions, and all scroll
    methods now use them. (`utopic_tui.dart`)
- **Fix AI reasoning text hidden during tool calls** — `_convToLines` had a
  `continue` statement that skipped the "Utopic" header and any content for
  assistant messages with tool calls. Now the header always shows, reasoning
  text is displayed before the tool call list. (`utopic_tui.dart`)

## 1.1.2

- **Fix emoji split on paste — surrogate pair corruption causing Zen API 500**
  - When pasting text containing emoji (surrogate pairs), `_cursor++` only
    advanced by 1 code unit, leaving the cursor between the high and low
    surrogates. Subsequent character insertion (e.g., `\n` from a paste)
    would split the pair, producing unpaired surrogates in the input string.
    When this corrupted string was sent to the Zen API, the server returned
    HTTP 500 (Internal server error) on every subsequent request in that
    session.
  - Fixed: `_cursor += ch.length` instead of `_cursor++` for printable input.
  - Fixed: Backspace and Delete now detect and remove whole surrogate pairs
    (2 code units) instead of splitting them.
  - Fixed: Arrow left/right skip over surrogate pairs so the cursor never
    lands between surrogates.
  (`utopic_tui.dart`)

## 1.1.1

- **Fix /phobe freeze + make --phobe actually remove pride content**
  - `/phobe` no longer freezes — handler now wrapped in try-catch
  - `--phobe` now changes the welcome message to a non-queer version
    instead of just toggling colors. The pride welcome is replaced with
    a neutral one: "Utopic here. Let's write some code."
  - `AgentService` gains a `phobeMode` field; the TUI sets it before
    `initialize()` so the welcome message respects the flag.
  - Phobe mode spinner shows plain "thinking" instead of rainbow emojis
  - Hint bar shows "— phobe mode" instead of "✦ fabulously queer"
  (`agent_service.dart`, `utopic_tui.dart`)

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
