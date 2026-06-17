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

## ✅ ACP Server — Refactored to `acp_dart` (`AgentSideConnection`)

**Goal:** Replace the hand-rolled ACP server with the official `acp_dart` package (`AgentSideConnection`), matching the client-side refactor.

### Phase 4 — Hand-rolled ACP server (pre-`acp_dart`)

| Commit | Description |
|---|---|
| `b519d3d` | Original ACP server with custom JSON-RPC + handler dispatch |

### Phase 5 — Switch to `acp_dart` package for server

| Commit | Description |
|---|---|
| `5dda980` | Wire up `--acp-server` CLI flag for headless ACP TCP server |
| `3ac05cf` | Add `--acp-stdio` flag for stdio-based ACP server (subprocess mode) |
| `e804c5a` | **Refactor ACP server to use `AgentSideConnection`** — replace custom parsing with `acp_dart`'s `Agent` interface (`AcpAgent` + `AcpAgentDelegate`) |
| `eb47891` | Include available models in `NewSessionResponse` for Paseo compatibility |
| `505e104` | Stream `session/update` notifications with agent reply text before final `PromptResponse` |
| `acd1e1f` | Update docs: README, PASEO_SETUP, ROADMAP, TASKLIST |

---

## 🧹 Obsolete Branch — Replaced by `acp_dart` Refactor ⚠️

The commits below live on a dangling branch forked from `99f3397` (before the
`acp_dart` package migration). Most are **obsolete** — the files they touch
(`acp_client.dart`, `direct_terminal.dart`) were replaced or removed in the
`acp_dart` refactor. The features are still worth having but need fresh
implementations against `main`.

### Features to rebuild (see ROADMAP.md → Up Next)

| Feature | Original commit | Notes |
|---------|----------------|-------|
| Input history (Shift+↑/↓) | `00cab81` | Needs clean impl in current TUI |
| `/clear` command | `00cab81` | Easy, self-contained |
| ACP auto-start on boot | `00cab81` | Read `acp.enabled` from config |
| Auto-compaction | `a319137` | Trim old messages when too long |
| `/compact` command | `04ecd49` | Manual compaction trigger |
| ACP server timeout fixes | `f2fc5cc` | May already be resolved by `acp_dart` |
| String ID support (JSON-RPC 2.0) | `52a4207` | May already be handled by `acp_dart` |

### Already ported to `main`

| Commit | Description | Status |
|---|---|---|
| `26de909` | AGENTS.md for agent context | ✅ Done — reviewed and written fresh for current arch |
| `63b4985` | ACP client overhaul + AOT stdout bug + scroll fix | 🗑️ Obsolete — ACP client replaced by `acp_dart`; scroll fix handled separately in `b48ff9e`; AOT bug workaround (`direct_terminal.dart`) not needed on main |

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