# Paseo Context Indicator + Compact — Implementation Plan

> Stored on `2025-06-22` · Last updated `2025-06-22` after Phase A.
> Pick up where we left off! 💖

---

## ✅ Phase A: Accurate Context Indicator 🎯 — DONE

> **Implemented and merged.** Zero lint errors, all tests pass.

### What Changed

#### `lib/src/models/conversation.dart` — Context tracking fields

| Addition | Purpose |
|---|---|
| `contextTokens` | Tracks actual token count (from API) or estimate (before first call) |
| `contextLimit` | The model's context window size (e.g. `200000` for Claude) |
| `estimateTokens()` | Static — rough fast estimate (~1 token per 3.5 chars) |
| `serializeContext()` | Produces conversation as plain text for estimation |
| `estimateContextTokens()` | Convenience — calls both above |
| `contextUsageFraction` | Returns `0.0` to `1.0` |
| `contextSummary` | Returns `"45%  (92K/200K)"` — ready for display |
| JSON round-trip | New fields serialized in `toJson()` / `fromJson()` |

#### `lib/src/services/agent_service.dart` — Accurate tracking

| Fix | What |
|---|---|
| ❌ **Removed accumulation bug** | No more `totalInputTokens += result.inputTokens` (over-counted) |
| ✅ **Authoritative token count** | `conv.contextTokens = result.inputTokens` — real count from API |
| ✅ **Initial UsageUpdate** | Sent at start of `_runAgentLoop` with estimate, so Paseo shows bar immediately |
| ✅ **`syncContextLimit()`** | Called at loop start & after every API call to keep `conv.contextLimit` in sync |
| ✅ **`setModel()` method** | Sets model + syncs context limit in one call |
| ✅ **Cost calculation** | Simplified to `used * 0.000001` (blended rate) |
| ✅ **`createNewConversation()`** | Now sets context limit from current model |
| ✅ **`loadSession()`** | Estimates tokens for legacy sessions without `contextTokens` |

#### `lib/src/models/zen_models.dart` — Accurate model limits

- **`contextLimitFor()`** — looks up model's limit, falls back to family-based
  defaults (Claude=200K, Gemini=1M, GPT/DeepSeek=128K)
- **Filled in all missing `contextLimit` values** in the model list

#### `lib/src/tui/utopic_tui.dart` — Live context bar in status

When there's context data, the status bar appends:
```
📊 12%  (24K/200K)
```
Only shows if there's room in the terminal width. Uses `conv.contextSummary`.

### Data Flow (for Paseo)

```
sendMessage() → _runAgentLoop()
                  ├── conv.contextLimit = ZenModels.contextLimitFor(model)
                  ├── conv.contextTokens = conv.estimateContextTokens()
                  ├── sendUsage()  ← Paseo gets initial bar 📊
                  │
                  ├── round 1: ai.complete()
                  │   └── conv.contextTokens = result.inputTokens  ← real count
                  │   └── sendUsage()  ← Paseo gets updated bar
                  │
                  ├── round 2: ai.complete()
                  │   └── conv.contextTokens = result.inputTokens  ← no accumulation!
                  │   └── sendUsage()  ← bar updates, doesn't double-count
                  │
                  └── done → sendUsage()  ← final bar
```

### Files Changed (Phase A — actual)

| File | What |
|---|---|
| `lib/src/models/conversation.dart` | Added `contextTokens`, `contextLimit`, `estimateTokens()`, `serializeContext()`, `estimateContextTokens()`, `contextUsageFraction`, `contextSummary` |
| `lib/src/services/agent_service.dart` | Fixed `_runAgentLoop` tracking, added initial `sendUsage()`, updated `sendUsage()`, added `setModel()` + `syncContextLimit()`, updated `createNewConversation()` and `loadSession()` |
| `lib/src/models/zen_models.dart` | Filled all missing `contextLimit` values, added `contextLimitFor()` |
| `lib/src/tui/utopic_tui.dart` | Added context usage bar in status area, `/model` uses `setModel()` |

---

## Phase B: Manual Compact 🧹

> **Goal:** User (or Paseo) can trigger a compact that summarizes older messages
> and frees context space.

### What Is Compact?

Before:
```
User: "Let's build a REST API with auth"
Assistant: [20 rounds of building models, controllers, tests...]
User: "Now add rate limiting"
```

After compact:
```
System: "[Compact summary: Built a complete REST API in Flask with JWT auth,
         SQLAlchemy models for User/Project/Task, CRUD controllers, and
         pytest test suite covering all endpoints. Current working state:
         all 47 tests pass.]"
User: "Now add rate limiting"
```

### Design Decisions

**Where to compact:**
- **Utopic-side** ✅ — it has the full conversation and knows what's important
- Paseo-side — Paseo doesn't have the message content, only receives updates

**Compact strategy:**
- Keep the last **N messages** verbatim (configurable, default 5-10)
- Take everything before the watermark and ask the LLM to produce a summary
- Replace compacted messages with a single `system` message containing the summary

**Safety:**
- Store compacted messages to disk (already in session store)
- The summary should be **detailed** — include file paths, function names,
  key decisions, test counts, error states
- Allow a `/compact undo` or load the pre-compact session from `/list`

### Implementation

#### 1. `lib/src/services/agent_service.dart` — `compactConversation()`

```dart
Future<void> compactConversation({int keepRecent = 8}) async {
  final conv = _activeConv;
  if (conv == null || conv.messages.length <= keepRecent + 1) return;

  // 1. Determine watermark — keep the last `keepRecent` messages
  final watermark = conv.messages.length - keepRecent;

  // 2. Build the "history" text from messages before the watermark
  final historyMessages = conv.messages.sublist(0, watermark);
  final historyText = historyMessages.map((m) =>
    '[${m.role}]: ${m.content}'
    + (m.toolCalls != null ? '\n  [tool calls: ${m.toolCalls!.length}]' : '')
  ).join('\n\n');

  // 3. Call LLM to produce a detailed summary
  //    Use a low-cost model if available
  final summaryPrompt = '''
You are a conversation compactor. Produce a detailed, factual summary of the
following conversation history. Include:
- Files created/modified and their paths
- Key functions, classes, and architectural decisions
- Test results, error states, and current working state
- Any configuration or setup decisions made

Keep the summary under 400 tokens. Be precise — the AI will rely on this
summary for future context.

History:
$historyText

Summary:
''';

  // 4. Get summary from AI (use current model or a cheap one)
  //    This is a simple completion, not a full tool-calling loop
  final summary = await _getCompactSummary(summaryPrompt);

  // 5. Replace compacted messages with a single system message
  final compactMsg = Message(
    role: 'system',
    content: '[Compacted conversation history — ${watermark} messages]\n\n$summary',
  );

  conv.messages.removeRange(0, watermark);
  conv.messages.insert(0, compactMsg);

  // 6. Update contextTokens estimate (since we haven't called the API yet)
  conv.contextTokens = estimateTokens(serializeConversation(conv));

  // 7. Send UsageUpdate to Paseo so the bar drops
  await sendUsage();

  // 8. Notify UI
  _notifyUpdates();
}
```

#### 2. ACP Extension — allow Paseo to trigger compact

Add a handler in `_runAgentLoop` or a dedicated ACP method.

Using `extMethod` / `extNotification` (available in `acp_dart`):

```dart
// In AcpAgent (acp_agent.dart)
@override
Future<Map<String, dynamic>>? extMethod(
    String method, Map<String, dynamic> params) async {
  if (method == 'session/compact') {
    await delegate.onCompact(
      sessionId: params['sessionId'] as String,
      keepRecent: params['keepRecent'] as int? ?? 8,
    );
    return {'status': 'ok'};
  }
  return null;
}
```

#### 3. TUI `/compact` command

```dart
// In _runCommand (utopic_tui.dart)
case 'compact':
  _status = '🧹 Compacting...';
  _agent.compactConversation(keepRecent: 8).then((_) {
    _status = 'Compacted ✅  ·  ${_agent.ai.currentModel}';
    _refreshChat(context);
  }).catchError((e) {
    _status = 'Compact error: $e';
  });
  return;
```

### Files Changed (Phase B)

| File | What |
|---|---|
| `lib/src/services/agent_service.dart` | Add `compactConversation()`, `_getCompactSummary()` |
| `lib/src/acp/acp_agent.dart` | Handle `session/compact` ext method |
| `lib/src/acp/acp_types.dart` | (Optional) add `AcpMethods.sessionCompact` constant |
| `lib/src/tui/utopic_tui.dart` | Add `/compact` command |

---

## Phase C: Auto-Compact 🤖

> **Goal:** When context usage crosses a threshold, automatically compact to
> free space — seamless, with a clear thought update to the user/Paseo.

### Implementation

#### 1. Configurable Threshold

Add to `AppConfig` or a per-conversation setting:

```yaml
# utopic.yaml
compact:
  autoCompaction: true
  compactionThreshold: 0.85  # 85% of context window
  keepRecent: 8              # messages to keep verbatim
```

#### 2. Trigger in `_runAgentLoop`

After each round (or before the next AI call), check:

```dart
// Inside _runAgentLoop, after sendUsage():
final threshold = config.compactThreshold ?? 0.85;
if (autoCompaction && conv.contextTokens > conv.contextLimit * threshold) {
  await sendThought('🧹 **Auto-compacting context window** to free space...');
  await compactConversation(keepRecent: config.keepRecent ?? 8);
  // sendUsage is called inside compactConversation
}
```

#### 3. Thinking Update

Paseo will show:
```
🧹 Auto-compacting context window — summarizing 24 earlier messages...
```

Then a fresh `UsageUpdate` with the new, lower token count.

### Design Considerations

- **Don't compact if already compacted** — track a `_compactedAt` or
  `_compactedCount` to avoid infinite compact loops.
- **Don't compact during tool execution** — only between rounds.
- **Threshold should be slightly below the model's hard limit** to give the
  next round room for output tokens.
- **Allow user to disable** with `/config autoCompact=false` or via Paseo.

### Files Changed (Phase C)

| File | What |
|---|---|
| `lib/src/services/agent_service.dart` | Auto-compact trigger in `_runAgentLoop` |
| `lib/src/config/app_config.dart` | Add `compactThreshold`, `autoCompaction`, `keepRecent` settings |
| `lib/src/models/conversation.dart` | Track `compactedCount` to prevent loops |

---

## Summary: Phased Rollout

```
Phase A ── Accurate context indicator  ✅ DONE
  ├── Fix token tracking
  ├── Send initial UsageUpdate
  ├── Fill in missing context limits
  └── (Optional) TUI context bar

Phase B ── Manual compact  ⬅️ NEXT
  ├── compactConversation() method
  ├── ACP extMethod handler for Paseo
  ├── /compact TUI command
  └── UsageUpdate after compact

Phase C ── Auto-compact
  ├── Configurable threshold & settings
  ├── Auto-trigger in agent loop
  ├── Thought notification to Paseo
  └── Safety checks (no infinite loops)
```

---

## Open Questions / Future Thoughts

1. **Side-effect safety** — compacting discards detail. Should we save the
   full pre-compact conversation to disk so it can be referenced later?
   (Session store already does this per-save, but explicitly linking to
   "ancestor sessions" could be cool.)

2. **Multiple compact levels** — could offer "light" (summarize only tool
   results) vs "deep" (summarize everything). Light would be safer.

3. **Paseo compact button** — if Paseo adds a compact button in its UI,
   it sends the `session/compact` ext method. We should document the ACP
   extension in `PASEO_SETUP.md`.

4. **Streaming compact progress** — for very large conversations, compact
   could take a while. Could stream the summary as it's being generated
   via `AgentMessageChunkSessionUpdate`.

5. **Context limit negotiation** — when connecting via ACP, the server
   could tell the client the model's context limit via `_meta` in the
   `NewSessionResponse` model info (already partially implemented in
   `acp_agent.dart`).

---

## What's Next 🏳️‍🌈

Phase A is **done** and merged. Next up:

- **Phase B** → implement `compactConversation()`, ACP `session/compact` ext,
  `/compact` TUI command, and `UsageUpdate` after compact
- **Phase C** → auto-compact trigger with configurable threshold

Let's build something marvelous! 💖
