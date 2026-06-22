import 'dart:async';
import 'dart:io';

import 'package:acp_dart/acp_dart.dart';

import 'acp_agent.dart';

/// ACP server using [AgentSideConnection] for transport.
///
/// Supports TCP and stdio modes. Each TCP connection creates its own
/// [AgentSideConnection] + [AcpAgent] pair, sharing [delegate] state.
class AcpServer {
  final String host;
  final int port;
  final String? socketPath;
  final AcpAgentDelegate delegate;

  ServerSocket? _tcpServer;
  ServerSocket? _unixServer;
  bool _isRunning = false;
  final _connections = <_ServerConnection>[];
  _ServerConnection? _stdioConnection;
  final Completer<void> _doneCompleter = Completer<void>();

  /// The port the TCP server is bound to (useful when binding to port 0).
  int? get boundPort => _tcpServer?.port;

  /// The host address the server is listening on.
  String get boundHost => host;

  bool get isRunning => _isRunning;

  /// A future that completes when the server stops.
  Future<void> get done => _doneCompleter.future;

  AcpServer({
    this.host = '127.0.0.1',
    this.port = 8080,
    this.socketPath,
    required this.delegate,
  });

  /// Start the server listening on TCP or Unix socket.
  Future<void> start() async {
    if (_isRunning) return;

    if (socketPath != null && socketPath!.isNotEmpty) {
      final socketFile = File(socketPath!);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
      _unixServer = await ServerSocket.bind(socketPath!, 0);
      _unixServer!.listen(_handleClient);
    } else {
      _tcpServer = await ServerSocket.bind(host, port);
      _tcpServer!.listen(_handleClient);
    }

    _isRunning = true;
  }

  /// Start the server reading from stdin and writing to stdout.
  Future<void> startStdio() async {
    if (_isRunning) return;

    _isRunning = true;
    _stdioConnection = _ServerConnection._stdio(this);
    _stdioConnection!._start();
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    final connections = List<_ServerConnection>.from(_connections);
    for (final conn in connections) {
      await conn._close();
    }
    _connections.clear();

    await _stdioConnection?._close();
    _stdioConnection = null;

    await _tcpServer?.close();
    await _unixServer?.close();

    if (socketPath != null) {
      final socketFile = File(socketPath!);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
    }

    _isRunning = false;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  void _handleClient(Socket socket) {
    final conn = _ServerConnection._tcp(this, socket);
    _connections.add(conn);
    conn._start();
  }

  void _removeConnection(_ServerConnection conn) {
    _connections.remove(conn);
  }
}

/// Manages a single ACP connection (TCP socket or stdio).
class _ServerConnection {
  final AcpServer _server;
  final Socket? _socket;
  final bool _isStdio;

  _ServerConnection._tcp(this._server, this._socket)
      : _isStdio = false;

  _ServerConnection._stdio(this._server)
      : _socket = null,
        _isStdio = true;

  void _start() {
    if (_isStdio) {
      // Wrap stdin to detect EOF without conflicting with ndJsonStream
      final inputController = StreamController<List<int>>();
      stdin.listen(
        inputController.add,
        onError: inputController.addError,
        onDone: () {
          inputController.close();
          _server.stop();
        },
        cancelOnError: false,
      );
      final raw = ndJsonStream(inputController.stream, stdout);
      final stream = _ensureParams(raw);
      AgentSideConnection(
        (conn) => AcpAgent(conn, _server.delegate),
        stream,
      );
    } else if (_socket != null) {
      final raw = ndJsonStream(_socket.cast<List<int>>(), _socket);
      final stream = _ensureParams(raw);
      AgentSideConnection(
        (conn) => AcpAgent(conn, _server.delegate),
        stream,
      );
      // Detect client disconnect via socket.done Future
      _socket.done.then((_) => _server._removeConnection(this));
    }
  }

  /// Wraps an [AcpStream] to fix missing/null params for methods that
  /// require them.
  ///
  /// Workaround for `acp_dart` crashing when `params` is null (e.g. bare
  /// `{"method":"initialize"}` with no params key), or when required
  /// sub-fields like `mcpServers` or `prompt` are missing/wrong type.
  ///
  /// This is needed because some ACP clients (including Paseo) may omit
  /// optional-looking but actually-required fields in their JSON-RPC requests.
  AcpStream _ensureParams(AcpStream original) {
    final fixed = original.readable.map((msg) {
      final method = msg['method'] as String?;
      if (method == null) return msg;

      // If params is completely missing, add empty map
      if (!msg.containsKey('params')) {
        msg['params'] = method == 'initialize'
            ? <String, dynamic>{'protocolVersion': 1}
            : <String, dynamic>{};
      }

      final params = msg['params'];
      if (params is! Map<String, dynamic>) return msg;

      // session/new requires mcpServers but some clients omit it
      if (method == 'session/new' && !params.containsKey('mcpServers')) {
        params['mcpServers'] = <dynamic>[];
      }

      // session/prompt expects prompt as a List<ContentBlock>, but some
      // clients send a plain string. Convert it.
      if (method == 'session/prompt' && params.containsKey('prompt')) {
        final prompt = params['prompt'];
        if (prompt is String) {
          params['prompt'] = <Map<String, dynamic>>[
            {'type': 'text', 'text': prompt},
          ];
        }
      }

      // session/set_model needs modelId as a required field
      if (method == 'session/set_model' &&
          params.containsKey('modelId') &&
          params['modelId'] is! String) {
        // Ensure modelId is a string
        params['modelId'] = params['modelId'].toString();
      }

      return msg;
    });
    return AcpStream(readable: fixed, writable: original.writable);
  }

  Future<void> _close() async {
    try {
      if (!_isStdio) _socket?.close();
    } catch (_) {}
  }
}
