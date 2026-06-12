## 1.0.0

- Initial version.

## 1.1.0

- Add ACP client support — utopic can connect to remote ACP servers and use
  them as model providers (`/acp-connect`, `/acp-disconnect` commands).
- Refactor `AiService` to abstract class with `ZenAiService` and `AcpAiService`
  implementations.
- Add `AcpClient` class for JSON-RPC 2.0 over TCP client connections.
- Add `acp.clients` config for auto-connect on startup.
- Add AcpClient test suite.
