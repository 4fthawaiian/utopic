# Utopic — Roadmap

## ✅ Done

### ACP Client — Connect to Remote ACP Servers via `acp_dart`

**Problem:** utopic could only *host* an ACP server for other tools. It
couldn't *connect* to external ACP agents as model providers.

**Solution:** Replaced the hand-rolled ACP client with the official
[`acp_dart`](https://pub.dev/packages/acp_dart) package (`ClientSideConnection`).
ACP connections use typed session management, config option discovery,
and proper notification handling.

Connection methods:
- `/acp-connect <host> <port>` — TCP connection
- `/acp-connect cli:<cmd>` — local subprocess (stdin/stdout)
- `/acp-connection` — alias for `acp-connect`
- `/acp-disconnect` — restore local Zen API provider

Tested with `devin acp` — 80+ models available via `/models`.

**Key fixes along the way:**
- `FileSystemCapability()` must be provided (Rust ACP server rejects `null`)
- ACP model options read from `NewSessionResponse.configOptions`
- Text chunks collected from `AgentMessageChunkSessionUpdate` notifications

---

### ACP Server — Refactored to `acp_dart` (`AgentSideConnection`)

**Problem:** The ACP server used a hand-rolled JSON-RPC implementation
with custom handler dispatch, message framing, and transport (TCP/stdio).

**Solution:** Replaced with `acp_dart`'s `AgentSideConnection` + `ndJsonStream`.
The server now implements the standard `Agent` interface via `AcpAgent`,
which delegates to `AgentService` through `AcpAgentDelegate`.

- `acp_agent.dart` — new `Agent` implementation
- `acp_server.dart` — thin transport wrapper (TCP/stdio) over `AgentSideConnection`
- Standard ACP method names: `session/new`, `session/prompt`, `session/cancel`, `session/list`, `fs/read_text_file`, `fs/write_text_file`, `terminal/create`, etc.
- Headless modes: `--acp-server` (TCP) and `--acp-stdio` (stdin/stdout)
- `session/new` returns models list for Paseo compatibility
- `session/prompt` streams reply via `session/update` notifications
- Legacy aliases maintained for backward compatibility

**Key fixes along the way:**
- `InitializeRequest` handling for missing params (bare `initialize`)
- `NewSessionRequest` requires `mcpServers` — injected if missing
- `ProtocolVersion` injected as `1` for bare initialize
- Stream wrapper injects default params for methods that require them

---

## Up Next

### 1. Readline-style input history

**The problem:** Every prompt is typed fresh — there's no way to recall or edit
a previous message.  Up-arrow should cycle through command history like bash/zsh.

**Sketch:**

```dart
final _history = <String>[];
int _historyIndex = -1;

void _handleKey(TuiKeyEvent event) {
  if (event.code == TuiKeyCode.arrowUp) {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _input = _history[_history.length - 1 - _historyIndex];
      _cursor = _input.length;
    }
  } else if (event.code == TuiKeyCode.arrowDown) {
    if (_historyIndex > 0) {
      _historyIndex--;
      _input = _history[_history.length - 1 - _historyIndex];
      _cursor = _input.length;
    } else if (_historyIndex == 0) {
      _historyIndex = -1;
      _input = '';
      _cursor = 0;
    }
  }
}

// On submit:
_history.add(text);
_historyIndex = -1;
```

Store history in `~/.config/utopic/history` (one line per entry, max 1000).

---

### 2. Persistent sessions — resume after exit

**The problem:** Conversations live only in memory.  When utopic exits, they're
gone.  Need a way to save and reload sessions.

**Sketch:**

Each session gets a human-readable ID built from two dictionary words:

```
session/amber-walrus
session/crimson-falcon
```

Or a UUID if preferred:

```
session/7f3a2b1c-9d4e-4f8a-a1b2-c3d4e5f6a7b8
```

Conversations are serialised to `~/.config/utopic/sessions/<id>.json`:

```json
{
  "id": "amber-walrus",
  "title": "Refactor auth module",
  "created": "2026-06-12T10:00:00Z",
  "updated": "2026-06-12T10:30:00Z",
  "cwd": "/home/user/project",
  "model": "claude-sonnet-4",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "refactor the auth module"},
    {"role": "assistant", "content": "..."}
  ]
}
```

On startup, load all session metadata (id + title + timestamps) into the
conversation list.  The full message history is loaded lazily when the user
switches to that session.

Commands:
- `/save` — persist the current session
- `/load <id>` — load a saved session
- Auto-save on exit and on each message.

---

## ACP Server — Hard Features

> These need architecture thought before implementation.  Each section below
> explains the problem, the current gap, and a sketch of what a solution could
> look like.

---

## 1. `agent/pause` / `agent/resume` — Mid-loop State Serialisation

### The problem

The agent loop (`_runAgentLoop` in `agent_service.dart`) is a synchronous
`while` loop inside an `async` method.  "Pausing" mid-iteration means:

1. Let the current `ai.complete()` call finish (or cancel it)
2. Capture the conversation state at that exact snapshot — including any
   pending tool results that haven't been fed back yet
3. Store it so a later `agent/resume` can pick up where it left off

The current `cancel()` mechanism just sets a flag and returns.  It doesn't
preserve the loop position.

### What would need to change

**State machine, not a while loop.**  The agent loop would become an explicit
state machine with phases:

```
WAITING → AI_CALL → TOOL_EXEC → AI_CALL → ... → DONE
```

Each phase transition is an event, and the conversation + phase index are
serialisable.  `agent/pause` writes the state machine to a JSON blob;
`agent/resume` rehydrates it and continues from the same phase.

**Key considerations:**

- The `AiService.complete()` HTTP request is in-flight when a pause request
  arrives.  Do we let it finish (wasteful but simple) or abort it?
- Tool execution has side effects (file writes, bash commands).  On resume,
  should we re-execute the tool or use the cached result?
- Multi-turn: a paused loop might have 3 completed tool calls and 2 pending.
  The conversation history must reflect exactly that.

### Sketch

```dart
enum AgentPhase { awaitingInput, aiCall, toolExecution, done }

class AgentState {
  final String conversationId;
  final AgentPhase phase;
  final int iteration;
  final List<Map<String, dynamic>> pendingToolCalls;
  final List<Map<String, dynamic>> completedToolResults;
  // JSON-serialisable — store in a Map, write to disk
}

Map<String, AgentState> _sessions = {};  // session_id → state

_acpServer!.registerHandler('agent/pause', (request) async {
  final sessionId = ...;
  _sessions[sessionId] = _captureState(sessionId);
  return { 'paused': true, 'session_id': sessionId };
});

_acpServer!.registerHandler('agent/resume', (request) async {
  final state = _sessions.remove(sessionId);
  return _resumeLoop(state);
});
```

### Priority: Low

The TUI already handles cancellation gracefully.  Pause/resume is useful
for external agents that want to delegate a long-running task and check
back later, but it's not blocking anything.

---

## 2. `fs/glob` — Pattern-based File Search

### The problem

There's no way to find files by pattern (e.g. `**/*.dart`) over ACP.  Users
currently have to use `terminal/run` with `find . -name '*.dart'`.

### What would need to change

A new handler that delegates to `dart:io`'s `Directory.listSync(recursive: true)`
with client-side filtering, or uses the `Glob` package.

### Sketch

```dart
_acpServer!.registerHandler('fs/glob', (request) async {
  final params = request.params as Map<String, dynamic>;
  final pattern = params['pattern'] as String? ?? '';
  final root = params['root'] as String? ?? '.';
  // Use dart:io Directory.listSync(recursive: true) + RegExp matching
  // or the `glob` package from pub.dev
  return { 'files': matches };
});
```

### Priority: Low

Workaround exists via `terminal/run` with `find`.  A dedicated endpoint
is cleaner but not urgent.

---

## 3. `fs/grep` — Content Search

### The problem

No way to search file contents by regex over ACP.

### What would need to change

Same as `fs/glob` — iterate files, read content, apply regex.  For large
projects this is slow without an index.

### Sketch

```dart
_acpServer!.registerHandler('fs/grep', (request) async {
  final params = request.params as Map<String, dynamic>;
  final pattern = params['pattern'] as String? ?? '';
  final path = params['path'] as String? ?? '.';
  // Walk files, read each, apply RegExp, return matches with line numbers
  return { 'matches': [{ file, line, content }] };
});
```

### Priority: Low

Same workaround — `terminal/run` with `grep -rn`.

---

## 4. `terminal/create` / `terminal/write` / `terminal/kill` / `terminal/wait` — Long-running Process Manager

### The problem

`terminal/run` is fire-and-forget: it spawns a process, waits for it to
finish, and returns stdout/stderr.  Some workflows need:

- Start a server, keep it running
- Write input to a REPL over time
- Kill a hung process by ID
- Wait for a process to finish in the background

### What would need to change

A `ProcessManager` class that tracks child processes in a
`Map<String, Process>` keyed by a terminal/session ID.

```dart
class ProcessManager {
  final _processes = <String, Process>{};

  Future<String> create(String command, {String? cwd}) async {
    final process = await Process.start('bash', ['-c', command],
        workingDirectory: cwd, runInShell: true);
    final id = 'term_${DateTime.now().millisecondsSinceEpoch}';
    _processes[id] = process;
    return id;
  }

  void write(String id, String input) {
    _processes[id]?.stdin.writeln(input);
  }

  Future<int> kill(String id) async {
    final p = _processes.remove(id);
    if (p == null) throw ArgumentError('no such terminal');
    p.kill();
    return await p.exitCode;
  }

  Future<ProcessResult> wait(String id) async {
    final p = _processes.remove(id);
    final code = await p.exitCode;
    final stdout = await p.stdout.transform(utf8.decoder).join();
    final stderr = await p.stderr.transform(utf8.decoder).join();
    return ProcessResult(p.pid, code, stdout, stderr);
  }
}
```

### Key considerations

- **Timeouts**: orphan processes must be cleaned up on a timer
- **Streaming**: `terminal/write` output needs to be readable — either
  buffered or streamed to the client
- **Sessions**: a process belongs to an ACP session; if the session is
  deleted, the process should be killed
- **Security**: a long-running `bash -c 'cat /dev/zero'` could DoS the
  server — need resource limits

### Priority: Medium

The lack of long-running process support is the biggest gap in the current
ACP implementation for real development workflows (start a dev server,
run a database migration, open an interactive REPL).

---

## 5. `terminal/resize` — PTY Resize

### The problem

If we ever support interactive terminals (like `bash -i` via a PTY), we'd
need to send SIGWINCH or ioctl calls when the client's terminal resizes.

### What would need to change

Very low priority.  Requires a PTY library (or spawning through `script(1)`)
and platform-specific ioctl calls.  Only relevant if `terminal/create`
ever supports interactive TTYs.

### Priority: Very low

---

## 6. ACP Server Auto-start on Boot

### The problem

The `/acp` TUI command starts the server.  There's no way to have it start
automatically when utopic launches.

### What would need to change

The `acp.enabled` field in `utopic.yaml` is read by `AppConfig` but never
checked by `AgentService.initialize()`.

```yaml
acp:
  enabled: true   # ← read but unused
```

At the end of `AgentService.initialize()`:

```dart
if (config.acp.enabled) {
  startAcpServer();
}
```

### Priority: Low

One-liner fix once you decide on the behaviour.

---

## 7. Unix Socket Support in the `/acp` Command

### The problem

The `AcpServer` supports binding to a Unix domain socket via
`socket_path`, but the `/acp` TUI command only starts a TCP server.
The config YAML already has `acp.socket_path` but it's ignored when
starting the server from the TUI.

### What would need to change

In `startAcpServer()` the socket path is used if non-empty — this already
works.  The `/acp` command just needs to pass it through, or you add a
`/acp-socket` command.

### Priority: Very low

Unix sockets are useful for local-only IPC (no port暴露), but TCP on
127.0.0.1 is effectively the same for most use cases.

---

## 8. Streaming Responses

### The problem

All ACP methods that return output (`agent/run`, `terminal/run`) wait for
the full response before returning.  For long-running agent loops or
commands, the client sees nothing until the very end.

### What would need to change

Switch from newline-delimited JSON-RPC to a streaming protocol.  Options:

- **Server-Sent Events (SSE)** over the same TCP socket — send events
  as `data: {...}\n\n` lines with a final `event: complete` line
- **Chunked responses** — send partial results as notifications
  (`"method":"agent/progress","params":{"text":"..."}`) before the final
  response

This is a major protocol change and would break all existing clients.

### Priority: Very low

The TUI doesn't stream either (the spinner just waits).  Streaming is nice
for chat-like UX but adds significant complexity.
