import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'acp_types.dart';

/// Standard initialize params sent during the ACP handshake.
const _initParams = {
  'protocolVersion': 'v1',
  'clientInfo': {
    'name': 'utopic',
    'version': '1.0.0',
  },
  'clientCapabilities': <String, dynamic>{},
};

// ============================================================================
// Abstract AcpClient
// ============================================================================

/// A JSON-RPC 2.0 client that connects to an ACP server.
///
/// Wire protocol is newline-delimited JSON (one JSON object per line,
/// terminated by `\n`).  Responses are matched to requests by their `id`.
///
/// Concrete implementations:
/// - [TcpAcpClient] — connects over TCP
/// - [StdioAcpClient] — spawns a local CLI subprocess, talks over stdin/stdout
abstract class AcpClient {
  /// Setter for notification callback.
  set onNotification(void Function(String method, Map<String, dynamic>? params)? handler);
  /// Human-readable label for this connection.
  String get label;

  /// Information about the remote server, populated after [connect].
  Map<String, dynamic>? serverInfo;

  bool get isConnected;

  /// Connect and call [initialize] to discover capabilities.
  /// Returns the server info.
  Future<Map<String, dynamic>> connect();

  /// Send a JSON-RPC 2.0 request and wait for the response.
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
  });

  /// Send a JSON-RPC 2.0 notification (no response expected).
  void notify(String method, {Map<String, dynamic>? params});

  /// Close the connection.
  Future<void> close();
}

// ============================================================================
// Shared JSON-RPC message handling
// ============================================================================

/// Manages pending JSON-RPC requests and parses incoming line-delimited
/// JSON responses.  Used by both TCP and stdio transports.
class _PendingManager {
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String _buffer = '';
  int _nextId = 1;
  void Function(String method, Map<String, dynamic>? params)? _onNotification;

  /// Register a callback for incoming JSON-RPC notifications (messages without an id).
  set onNotification(void Function(String method, Map<String, dynamic>? params)? handler) {
    _onNotification = handler;
  }

  /// Register a new request and return its id.
  int register(Completer<Map<String, dynamic>> completer) {
    final id = _nextId++;
    _pending[id] = completer;
    return id;
  }

  /// Remove a pending request by id (e.g. on timeout).
  void remove(int id) {
    _pending.remove(id);
  }

  /// Feed raw bytes from the transport into the line parser.
  /// Completes any pending requests whose responses arrive.
  void feed(List<int> data) {
    _buffer += utf8.decode(data);
    while (_buffer.contains('\n')) {
      final idx = _buffer.indexOf('\n');
      final line = _buffer.substring(0, idx);
      _buffer = _buffer.substring(idx + 1);

      if (line.trim().isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final id = json['id'] as int?;
        if (id != null && _pending.containsKey(id)) {
          final completer = _pending.remove(id)!;
          if (!completer.isCompleted) completer.complete(json);
        } else if (id == null) {
          final method = json['method'] as String?;
          if (method != null) {
            _onNotification?.call(method, json['params'] as Map<String, dynamic>?);
          }
        }
      } catch (_) {
        // non-JSON line — ignore
      }
    }
  }

  /// Fail all pending requests with [error] and clear the queue.
  void failAll(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  /// Whether there are any requests still waiting for a response.
  bool get hasPending => _pending.isNotEmpty;

  /// Serialise a request to a JSON line (with trailing newline).
  String encodeRequest(String method, int id, Map<String, dynamic>? params) {
    final request = {
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
      if (params != null) 'params': params,
    };
    return '${jsonEncode(request)}\n';
  }
}

// ============================================================================
// TcpAcpClient
// ============================================================================

class TcpAcpClient extends AcpClient {
  final String host;
  final int port;
  Socket? _socket;
  final _mgr = _PendingManager();
  StreamSubscription? _subscription;

  TcpAcpClient({required this.host, required this.port});

  @override
  set onNotification(void Function(String method, Map<String, dynamic>? params)? handler) {
    _mgr.onNotification = handler;
  }

  @override
  String get label => '$host:$port';

  @override
  bool get isConnected => _socket != null;

  @override
  Future<Map<String, dynamic>> connect() async {
    _socket = await Socket.connect(host, port)
        .timeout(const Duration(seconds: 5));

    _subscription = _socket!.listen(
      (data) => _mgr.feed(data),
      onError: _onError,
      onDone: _onDone,
    );

    final result = await _rpcCall(AcpMethods.initialize, params: _initParams);
    serverInfo = result;
    return result;
  }

  @override
  Future<Map<String, dynamic>> call(String method, {Map<String, dynamic>? params}) {
    return _rpcCall(method, params: params);
  }

  Future<Map<String, dynamic>> _rpcCall(String method, {Map<String, dynamic>? params}) async {
    if (_socket == null) throw StateError('not connected');

    final completer = Completer<Map<String, dynamic>>();
    final id = _mgr.register(completer);
    _socket!.write(_mgr.encodeRequest(method, id, params));

    try {
      final response = await completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _mgr.remove(id);
          throw TimeoutException('ACP call "$method" timed out after 120s');
        },
      );
      return _unwrapResponse(response);
    } catch (e) {
      _mgr.remove(id);
      rethrow;
    }
  }

  Map<String, dynamic> _unwrapResponse(Map<String, dynamic> response) {
    if (response.containsKey('error')) {
      final err = response['error'] as Map<String, dynamic>;
      throw AcpClientException(
        code: err['code'] as int? ?? -1,
        message: err['message'] as String? ?? 'unknown error',
        data: err['data'],
      );
    }
    return (response['result'] as Map<String, dynamic>?) ?? {};
  }

  @override
  void notify(String method, {Map<String, dynamic>? params}) {
    if (_socket == null) return;
    _socket!.write(
      '${jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      })}\n',
    );
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _mgr.failAll(Exception('Connection closed'));
  }

  void _onError(Object error) {
    _mgr.failAll(error);
    close();
  }

  void _onDone() {
    _mgr.failAll(Exception('Connection closed by remote'));
    _socket = null;
  }
}

// ============================================================================
// StdioAcpClient
// ============================================================================

/// Spawns a local CLI subprocess and communicates via stdin/stdout using
/// the same newline-delimited JSON-RPC 2.0 protocol.
class StdioAcpClient extends AcpClient {
  final String command;
  final List<String> arguments;
  Process? _process;
  final _mgr = _PendingManager();
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  final _stderrBuffer = StringBuffer();

  /// [command] is the executable path; [args] are optional arguments.
  StdioAcpClient({required this.command, this.arguments = const []});

  @override
  set onNotification(void Function(String method, Map<String, dynamic>? params)? handler) {
    _mgr.onNotification = handler;
  }

  @override
  String get label => 'cli:$command';

  @override
  bool get isConnected => _process != null;

  /// Stderr output collected since [connect] (useful for debugging).
  String get stderrOutput => _stderrBuffer.toString();

  @override
  Future<Map<String, dynamic>> connect() async {
    _process = await Process.start(command, arguments, mode: ProcessStartMode.normal);

    // Listen to stdout as raw bytes — avoids issues with utf8.decoder
    // splitting multi-byte sequences at chunk boundaries.
    _stdoutSub = _process!.stdout.listen(
      (data) => _mgr.feed(data),
      onError: _onError,
      onDone: _onStdoutDone,
    );

    // Collect stderr for diagnostics.
    _stderrSub = _process!.stderr
        .transform(utf8.decoder)
        .listen((s) => _stderrBuffer.write(s));

    final result = await _rpcCall(AcpMethods.initialize,
        params: _initParams, timeout: const Duration(seconds: 10));
    serverInfo = result;
    return result;
  }

  @override
  Future<Map<String, dynamic>> call(String method, {Map<String, dynamic>? params}) {
    return _rpcCall(method, params: params);
  }

  Future<Map<String, dynamic>> _rpcCall(String method,
      {Map<String, dynamic>? params, Duration timeout = const Duration(seconds: 120)}) async {
    if (_process == null) throw StateError('not connected');

    final completer = Completer<Map<String, dynamic>>();
    final id = _mgr.register(completer);
    _process!.stdin.write(_mgr.encodeRequest(method, id, params));

    try {
      final response = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _mgr.remove(id);
          throw TimeoutException('ACP call "$method" timed out after ${timeout.inSeconds}s');
        },
      );
      return _unwrapResponse(response);
    } catch (e) {
      _mgr.remove(id);
      rethrow;
    }
  }

  Map<String, dynamic> _unwrapResponse(Map<String, dynamic> response) {
    if (response.containsKey('error')) {
      final err = response['error'] as Map<String, dynamic>;
      throw AcpClientException(
        code: err['code'] as int? ?? -1,
        message: err['message'] as String? ?? 'unknown error',
        data: err['data'],
      );
    }
    return (response['result'] as Map<String, dynamic>?) ?? {};
  }

  @override
  void notify(String method, {Map<String, dynamic>? params}) {
    if (_process == null) return;
    _process!.stdin.write(
      '${jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      })}\n',
    );
  }

  @override
  Future<void> close() async {
    _mgr.failAll(Exception('Connection closed'));
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    _process?.kill();
    _process = null;
  }

  void _onError(Object error) {
    _mgr.failAll(error);
    close();
  }

  Future<void> _onStdoutDone() async {
    // When stdout closes, the subprocess has exited (or will exit momentarily).
    // Await the exit code so we can include it and any stderr in the error.
    if (_process == null) return;
    try {
      final code = await _process!.exitCode;
      if (_mgr.hasPending) {
        final detail = _stderrBuffer.isNotEmpty
            ? ' (stderr: ${_stderrBuffer.toString().trim()})'
            : '';
        _mgr.failAll(Exception('Subprocess exited with code $code$detail'));
      }
    } catch (_) {
      if (_mgr.hasPending) {
        _mgr.failAll(Exception('Subprocess stdout closed unexpectedly'));
      }
    }
    _process = null;
  }
}

// ============================================================================
// AcpClientException
// ============================================================================

/// Exception thrown when a remote ACP server returns a JSON-RPC error.
class AcpClientException implements Exception {
  final int code;
  final String message;
  final dynamic data;

  AcpClientException({required this.code, required this.message, this.data});

  @override
  String toString() => 'ACP error ($code): $message';
}