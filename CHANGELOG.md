## 1.0.0

- Initial version.

## 1.1.0

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
