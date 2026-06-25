# utopic

A queer-coded TUI AI coding agent built with [utopia_tui](https://pub.dev/packages/utopia_tui)
supporting **OpenCode Zen models**, **Agent Skills** (agentskills.io),
the **Agent Client Protocol (ACP)**, and [**Paseo**](https://paseo.sh).

🏳️‍🌈✨ *Your fabulously queer coding companion in the terminal. Built with Paseo, works great with Paseo.*

<img src="Utopic.png" alt="Utopic TUI screenshot" width="700">

## Table of Contents

- [Features](#features)
- [Quick start](#quick-start)
- [One-shot mode](#one-shot-mode)
- [Keys](#keys)
- [Commands](#commands)
- [Skills](#skills)
- [Sessions](#sessions)
- [System prompt](#system-prompt)
- [Models](#models)
- [ACP (Agent Client Protocol)](#acp-agent-client-protocol)
  - [ACP Server](#acp-server-utopic-as-backend-for-other-tools)
  - [ACP Client](#acp-client-remote-server-or-local-cli-as-model-provider)
- [Configuration](#configuration)
- [CLI](#cli)
- [Project structure](#project-structure)
- [Build](#build)

## Features

- 🖥️ **Terminal UI** — Non-modal, just type and send. Rainbow pride theming (toggle with `/phobe` or `--phobe`)
- 🤖 **OpenCode Zen** — Claude, GPT, Gemini, DeepSeek, Qwen pre-configured, live model list on startup
- 🌐 **OpenRouter** — Use 200+ models via OpenRouter (GPT-4o, Claude Sonnet, Gemini, Llama, Mistral, etc.), switch providers at runtime with `/provider`
- 🧠 **Skills** — Agent Skills spec (agentskills.io) — drop `skills/<name>/SKILL.md` in your project or `~/.config/utopic/skills/`
- 📄 **Flexible prompts** — YAML config, `AGENTS.md` (project + global), `--prompt` flag, per-conversation `/prompt`
- 🔄 **Agent loop** — Multi-iteration tool calling (bash, read, write, edit), configurable via `max_iterations` in `config.yaml` (default 10), cancel anytime with `Ctrl+C`
- 📊 **Context usage bar** — Shows token consumption in real-time (`45% (92K/200K)`) in the status bar, with live updates streamed over ACP to Paseo
- 📂 **Conversations** — Multiple conversations, switch between them
- ⚡ **One-shot mode** — `utopic "prompt"` prints the response and exits
- 🔌 **ACP Server + Client** — Agent Client Protocol server for external tools, plus client mode to use remote ACP servers as model providers

## Quick start

```bash
export OPENCODE_API_KEY="sk-..."
dart run           # run from source (Zen API)
```

Or use OpenRouter:

```bash
export OPENROUTER_API_KEY="sk-or-..."
dart run -- --openrouter   # run with OpenRouter provider
```

Or build once with `dart compile exe bin/utopic.dart -o utopic` and use `./utopic` for all subsequent runs.

## One-shot mode

```bash
./utopic "explain Rust's borrow checker"
utopic "refactor this function: ..." > output.md
dart run -- "what's in this directory?"
```

## Keys

| Key | Action |
|---|---|
| `Enter` | Send message |
| `Alt+Enter` | Insert newline |
| `↑` / `↓` | Scroll line up / down |
| `PgUp` / `PgDn` | Scroll page up / down |
| `Home` / `End` | Scroll to top / bottom |
| `←` / `→` | Move cursor in input |
| `type /command` | Run a command |
| `Ctrl+D` | Quit (like normal terminal EOF) |
| `Ctrl+C` | Cancel in-progress agent run |

## Commands

| Command | Action |
|---|---|
| `/help` | Show help |
| `/new` | New conversation |
| `/clear` | Clear current conversation |
| `/model` | Interactive model selector (arrows + Enter) |
| `/model <id>` | Switch model by ID |
| `/models` | List models |
| `/prompt` | Show current system prompt override |
| `/prompt <text>` | Set a custom system prompt for this conversation |
| `/acp` | Toggle ACP server |
| `/acp-connect <host> <port>` or `/acp-connect cli:<cmd>` | Connect to ACP provider (TCP or local CLI) |
| `/acp-connection` | Same as above (alias) |
| `/acp-disconnect` | Disconnect from ACP provider |
| `/save` | Save current conversation |
| `/load <id>` | Load a saved conversation (bare `/load` lists saved) |
| `/list` | List conversations (💾 = saved) |
| `/switch <n>` | Switch conversation |
| `/config` | Show current configuration |
| `/provider` | Show current AI provider (Zen / OpenRouter) |
| `/provider <zen\|openrouter>` | Switch AI provider at runtime |
| `/phobe` | Toggle pride theming on/off |
| `/quit` | Exit |

## Skills

utopic supports the [Agent Skills specification](https://agentskills.io/specification).

Place a skill directory with a `SKILL.md` file (YAML frontmatter + markdown body):

```
project/
├── skills/
│   └── git-expert/
│       └── SKILL.md
└── ...
```

Or install globally in `~/.config/utopic/skills/<name>/SKILL.md`.

Skills are loaded progressively per spec:
1. **Startup** — metadata (name + description) scanned, validated, and kept in memory
2. **On match** — full SKILL.md body is loaded when the user's message is relevant
3. **On demand** — reference files (`references/`, `scripts/`, `assets/`) are accessible via tools

Pre-installed skills:
- **git-expert** — git version control workflows (commit, branch, merge, rebase, etc.)

## Sessions

Conversations are **auto-saved** to `~/.config/utopic/sessions/<id>.json` after
every exchange. On startup, utopic resumes your most recent session.

**Commands:**

| Command | Action |
|---|---|
| `/save` | Save the current conversation now |
| `/load` | List all saved sessions with IDs |
| `/load <id>` | Load and switch to a saved session |

**Resume from the CLI:**

```bash
./utopic --load conv_1781591223779_69697
```

The session ID is shown in the exit message so you can copy it for later.
Sessions are stored as plain JSON — peek at them anytime:

```bash
ls ~/.config/utopic/sessions/
cat ~/.config/utopic/sessions/conv_*.json | head -20
```

## System prompt

Built from up to **5 sources** — sources 1–4 are **merged (concatenated)** in order,
while source 5 acts as a **complete override** that replaces everything above:

1. **Default or YAML** — hardcoded prompt with queer energy, or `system_prompt` in `config.yaml`
2. **`AGENTS.md` / `AGENT.md`** (case-insensitive, e.g. `agents.md`) — auto-detected in the current directory (first match wins)
3. **`~/.config/utopic/AGENTS.md`** (or `AGENT.md`, case-insensitive) — global fallback if no project AGENTS.md found
4. **`--prompt <file>`** — CLI flag to inject a prompt file
5. **`/prompt <text>`** — per-conversation override (**replaces** all of the above)

```
# config.yaml
system_prompt: |
  You are Utopic, a coding agent. You are concise and write production-ready code.
```

```bash
./utopic --prompt instructions.md
```

```
> /prompt You are a Python expert. Only write Python code.
✅ System prompt updated for this conversation.
```

## Models

Utopic supports **two AI providers** — switch between them with `/provider`:

### OpenCode Zen (default)

Models are fetched from the OpenCode API on startup. Free models available:

- `deepseek-v4-flash-free` — DeepSeek (free)
- `mimo-v2.5-free` — Mimo (free)
- `qwen3.6-plus-free` — Qwen (free)
- `nemotron-3-ultra-free` — NVIDIA (free)
- `north-mini-code-free` — North (free)

Plus paid models from Anthropic, OpenAI, Google, DeepSeek, and more.

### OpenRouter

200+ models via [OpenRouter](https://openrouter.ai/models), including:

- `openai/gpt-4o`, `openai/gpt-4o-mini`, `openai/o3-mini`
- `anthropic/claude-sonnet-4`, `anthropic/claude-3.5-sonnet`
- `google/gemini-2.0-flash-001`, `google/gemini-2.0-pro-001`
- `deepseek/deepseek-r1`, `deepseek/deepseek-v3`
- `meta-llama/llama-3.3-70b-instruct`, `mistralai/mistral-large-2411`
- And many more — fetched live from the OpenRouter API

⚠️ OpenRouter requires an API key (`openrouter_api_key` in config or `OPENROUTER_API_KEY` env var).

Use `/model` to pick a model interactively, or `/model <id>` to set directly.
When you select a model from the other provider, Utopic auto-switches providers for you.

## ACP (Agent Client Protocol)

utopic runs an **ACP server** that external tools can use as a backend agent,
and an **ACP client** that lets utopic use remote ACP servers as model providers.

### ACP Server (utopic as backend for other tools)

Utopic can act as an ACP agent for external tools like **Paseo**. Two modes:

**Stdio (recommended for subprocess-based tools):**

```bash
dart run -- --acp-stdio
# or compiled: ./utopic --acp-stdio
```

This spawns utopic as a JSON-RPC 2.0 endpoint over **stdin/stdout** —
no network port needed. The tool launches utopic as a subprocess and
communicates through pipes.

**TCP (for network-based tools):**

```bash
/acp          # start the server inside the TUI
→ Listening on tcp://127.0.0.1:8080

# or headless:
dart run -- --acp-server
```

ACP methods supported: `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/list`, `session/set_config_option`, `session/set_model`, `session/set_mode`.

> **Note:** Filesystem (`fs/*`) and terminal methods are not yet implemented in the ACP server. These are planned for a future release.

### ACP Client (remote server or local CLI as model provider)

Connect utopic to another ACP server (TCP or local subprocess) and use it as
the AI model provider. The remote handles its own agent loop (tool calls,
file ops, etc.) internally — utopic just forwards your prompt and displays
the result.

**TCP:**
```
> /acp-connect 10.0.0.5 8080
ACP: other-agent (claude-sonnet-4) @ 10.0.0.5:8080
```

**Local CLI (spawns subprocess, talks over stdin/stdout):**

Works great with `devin acp`:
```
> /acp-connection cli:devin acp
ACP: affogato (swe-1-6-fast) via devin
```

Or any other ACP-compatible CLI:
```
> /acp-connect cli:my-agent --model claude
ACP: my-agent (claude-sonnet-4) via my-agent
```

Both `/acp-connect` and `/acp-connection` work (alias).

Once connected, `/models` lists all models from the remote server — select
one interactively via `/model` or set directly with `/model <id>`.

Disconnect to fall back to the local Zen API provider:

```
> /acp-disconnect
ACP disconnected  ·  deepseek-v4-flash-free
```

Auto-connect on startup via config (planned, not yet implemented):

```yaml
acp:
  clients:
    - host: "10.0.0.5"
      port: 8080
```

> ⚠️ Auto-connect on startup is a planned feature. For now, use `/acp-connect`
> interactively to connect to remote ACP providers.

## Configuration

Config is loaded with the following sources (later sources fill in missing values from earlier ones — not a strict override chain):

1. `--config <path>` CLI flag (highest precedence — points to a specific file)
2. `$UTOPIC_CONFIG` environment variable
3. `./config.yaml` (project-local)
4. `~/.config/utopic/config.yaml` (user-level)
5. `~/.config.yaml` (legacy fallback)

> **Note:** Unlike a traditional priority chain, later configs only **fill in** values
> not set by earlier configs. A value set in `./config.yaml` cannot be overridden
> by `~/.config/utopic/config.yaml` — the first file with that key wins.
> Environment variables (`OPENCODE_API_KEY`, `OPENROUTER_API_KEY`) serve as
> final fallbacks if no config file provides the key.

**`provider`** — which AI provider to use by default: `zen` or `openrouter`.
Can be overridden at runtime with `/provider` or the `--openrouter` CLI flag.

**`max_iterations`** — maximum rounds of AI + tool calls before the agent stops
(prevents runaway loops). Default: 10. Increase for complex multi-step tasks.

**Model (Zen)** — set via `default_model` (e.g. `deepseek-v4-flash-free`).

**Model (OpenRouter)** — set via `default_openrouter_model` (e.g. `openai/gpt-4o`).

**OpenRouter API key** — provide via `OPENROUTER_API_KEY` env var or `openrouter_api_key` in YAML.

**OpenRouter endpoint** — set via `openrouter_endpoint` (default: `https://openrouter.ai/api/v1`).

**ACP server auto-start** — set `acp.enabled: true` to start the server on boot (planned, not yet implemented — use `--acp-server` or `--acp-stdio` for now).

**API key (Zen)** — provide via `OPENCODE_API_KEY` env var or `opencode_api_key` in YAML.

## CLI

```bash
./utopic --help
./utopic --prompt my-prompt.md     # inject a prompt file
./utopic --openrouter              # start with OpenRouter provider
./utopic --phobe                   # launch without pride theming
./utopic --config path/to/yaml       # use a specific config file
./utopic --load conv_xxx...          # resume a saved session
./utopic "write a go routine"        # one-shot (print response, exit)
```

## Project structure

```
lib/
├── utopic.dart
└── src/
    ├── acp/              # ACP protocol types, server, client
    ├── config/           # YAML/env config loading
    ├── models/           # Zen models catalog, conversation model
    ├── services/         # AI service (Zen API), agent loop, skills, tools
    ├── tui/              # TUI app (build + event handling)
    └── vendor/           # Vendored utopia_tui runner (Ctrl+D exit)
bin/utopic.dart           # Entry point
```

## Build

```bash
dart compile exe bin/utopic.dart -o utopic
```
