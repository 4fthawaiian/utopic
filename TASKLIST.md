# Utopic — Task List

> Work done as part of the ACP integration and TUI refinement sprint.
> Commits are real (not simulated) — see `git log` for details.

---

## ✅ ACP Client — Connect to Remote ACP Servers via `acp_dart`

**Goal:** Replace the hand-rolled ACP client/server code with the official
[`acp_dart`](https://pub.dev/packages/acp_dart) package and get model
listing working with `devin acp`.

### Phase 1 — Hand-rolled ACP client (pre-`acp_dart`)

These commits built and debugged a custom ACP client implementation before
the decision to switch to `acp_dart`.

| Commit | Description |
|---|---|
| `b299052` | Add ACP client support — use remote ACP servers as model providers |
| `b16b4fd` | Add StdioAcpClient — use local CLI subprocess as ACP provider |
| `54928ff` | Fix StdioAcpClient hang — detect early process exit + raw byte stdout |
| `cfa4e7d` | Fix StdioAcpClient error message — include exit code + stderr |
| `3e722b8` | Send initialize params (protocolVersion + clientInfo) in ACP handshake |
| `99f3397` | Fix model selector scrolling + wire ACP models; update roadmap |
| `ec19f47` | Fix ACP compile error: add onNotification setter + notification dispatch |
| `613a856` | Fix ACP client: session/prompt flow, dynamic IDs, server timeout/framing |
| `63c2384` | Fix ACP client: trim+dynamic id in feed, eager session init for model discovery |
| `253e122` | Add debug logging for ACP session init and notification flow |

### Phase 2 — Switch to `acp_dart` package

Migrated to the official typed package, which provides `ClientSideConnection`,
proper session management, and built-in model discovery.

| Commit | Description |
|---|---|
| `cda97dc` | Refactor ACP client to use official acp_dart package |
| `5186569` | Add debug logging for ACP connection flow |
| `71c061a` | **Fix ACP init — provide FileSystemCapability()** (Rust server rejects null) |
| `8843294` | Add file-based diagnostic logging for ACP connection debugging |
| `32d36ce` | Add 'acp-connection' as alias for 'acp-connect' command |
| `f151130` | Clean up debug logging from ACP debugging session |
| `5e069f9` | Remove leftover debug stderr logging |

### Phase 3 — Documentation

| Commit | Description |
|---|---|
| `e7cef2d` | Update README and ROADMAP with ACP client integration details |

---

## 🧹 Other Improvements (from the same sprint)

| Commit | Description |
|---|---|
| `63b4985` | Overhaul ACP client, fix AOT stdout bug, fix scroll/redraw, clean up |
| `26de909` | Add AGENTS.md for agent context |
| `00cab81` | Quick wins: input history, /clear, ACP auto-start, visible cursor |
| `a319137` | Add auto-compaction for long conversations |
| `04ecd49` | Add /compact command for manual compaction |
| `f2fc5cc` | Fix ACP server timeout issues |
| `52a4207` | Fix ACP id type to handle String IDs per JSON-RPC 2.0 spec |

---

## Key Technical Details

### FileSystemCapability fix

The Rust ACP server (`devin acp`) rejects `"fs": null` in the
`clientCapabilities` field during initialization. The `acp_dart` library's
`ClientCapabilities` class has `fs` as `FileSystemCapability?` without
`@JsonKey(includeIfNull: false)`, so it serialized as `null`. Fixed by
passing `FileSystemCapability()` (an empty but valid struct).

### Model discovery

Models are extracted from `NewSessionResponse.configOptions` — the
`configOptions` field in the response contains `SessionConfigOption` entries
with `id: "model"` and all available model IDs with display names.

### Notification handling

Response text chunks are collected via `AgentMessageChunkSessionUpdate`
notifications dispatched to `Client.sessionUpdate()`.
