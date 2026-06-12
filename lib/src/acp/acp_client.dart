import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'acp_types.dart';

/// A JSON-RPC 2.0 client that connects to a remote ACP server over TCP.
///
/// Wire protocol is newline-delimited JSON (one JSON object per line,
/// terminated by `\n`).  Responses are matched to requests by their `id`.
class AcpClient {
  final String host;
  final int port;
  Socket? _socket;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String _buffer = '';
  StreamSubscription? _subscription;
  int _nextId = 1;

  /// Information about the remote server, populated after [initialize].
  Map<String, dynamic>? serverInfo;

  AcpClient({required this.host, required this.port});

  bool get isConnected => _socket != null;

  /// Connect to the remote ACP server and call [initialize] to discover
  /// its capabilities.  Returns the server info.
  Future<Map<String, dynamic>> connect() async {
    _socket = await Socket.connect(host, port)
        .timeout(const Duration(seconds: 5));
    _buffer = '';

    _subscription = _socket!.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );

    final result = await call(AcpMethods.initialize);
    serverInfo = result;
    return result;
  }

  /// Send a JSON-RPC 2.0 request and wait for the response.
  ///
  /// Returns the `result` field from the response on success, or throws
  /// an [AcpClientException] if the remote returned an error.
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    if (_socket == null) throw StateError('not connected');

    final id = _nextId++;
    final request = {
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
      if (params != null) 'params': params,
    };

    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket!.write('${jsonEncode(request)}\n');

    try {
      final response = await completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException(
            'ACP call "$method" timed out after 120s',
          );
        },
      );

      if (response.containsKey('error')) {
        final err = response['error'] as Map<String, dynamic>;
        throw AcpClientException(
          code: err['code'] as int? ?? -1,
          message: err['message'] as String? ?? 'unknown error',
          data: err['data'],
        );
      }

      return (response['result'] as Map<String, dynamic>?) ?? {};
    } catch (e) {
      _pending.remove(id);
      rethrow;
    }
  }

  /// Send a JSON-RPC 2.0 notification (no response expected).
  void notify(String method, {Map<String, dynamic>? params}) {
    if (_socket == null) return;
    final notification = {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    _socket!.write('${jsonEncode(notification)}\n');
  }

  /// Close the connection.
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _buffer = '';

    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Connection closed'));
      }
    }
    _pending.clear();
  }

  void _onData(List<int> data) {
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
        }
      } catch (_) {
        // non-JSON line — ignore
      }
    }
  }

  void _onError(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
    close();
  }

  void _onDone() {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Connection closed by remote'));
      }
    }
    _pending.clear();
    _socket = null;
  }
}

/// Exception thrown when a remote ACP server returns a JSON-RPC error.
class AcpClientException implements Exception {
  final int code;
  final String message;
  final dynamic data;

  AcpClientException({required this.code, required this.message, this.data});

  @override
  String toString() => 'ACP error ($code): $message';
}