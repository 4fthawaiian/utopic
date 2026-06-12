import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'acp_types.dart';

class AcpServer {
  final String host;
  final int port;
  final String? socketPath;
  final Map<String, AcpRequestHandler> _handlers = {};
  AcpNotificationHandler? _onNotification;
  ServerSocket? _tcpServer;
  ServerSocket? _unixServer;
  final _clients = <_ClientConnection>[];
  bool _isRunning = false;

  /// The port the TCP server is bound to (useful when binding to port 0).
  int? get boundPort => _tcpServer?.port;

  /// The host address the server is listening on.
  String get boundHost => host;

  AcpServer({
    this.host = '127.0.0.1',
    this.port = 8080,
    this.socketPath,
  });

  bool get isRunning => _isRunning;

  void registerHandler(String method, AcpRequestHandler handler) {
    _handlers[method] = handler;
  }

  void setNotificationHandler(AcpNotificationHandler handler) {
    _onNotification = handler;
  }

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

  Future<void> stop() async {
    if (!_isRunning) return;

    // Copy list before iterating: client.close() -> _removeClient() mutates _clients
    final clients = List<_ClientConnection>.from(_clients);
    for (final client in clients) {
      await client.close();
    }
    _clients.clear();

    await _tcpServer?.close();
    await _unixServer?.close();

    if (socketPath != null) {
      final socketFile = File(socketPath!);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
    }

    _isRunning = false;
  }

  void _handleClient(Socket socket) {
    final client = _ClientConnection(socket, this);
    _clients.add(client);
    client.start();
  }

  void _removeClient(_ClientConnection client) {
    _clients.remove(client);
  }

  void sendNotification(String method, {dynamic params}) {
    final notification = AcpNotification(method: method, params: params);
    final json = '${jsonEncode(notification.toJson())}\n';
    final data = utf8.encode(json);

    for (final client in _clients) {
      client.send(data);
    }
  }

  Future<void> _handleRequest(_ClientConnection client, AcpRequest request) async {
    final handler = _handlers[request.method];

    if (handler == null) {
      final errorResponse = AcpResponse(
        id: request.id,
        error: AcpError(code: -32601, message: 'Method not found: ${request.method}'),
      );
      client.sendResponse(errorResponse);
      return;
    }

    try {
      final result = await handler(request);
      final response = AcpResponse(id: request.id, result: result);
      client.sendResponse(response);
    } catch (e) {
      final errorResponse = AcpResponse(
        id: request.id,
        error: AcpError(code: -32603, message: e.toString()),
      );
      client.sendResponse(errorResponse);
    }
  }
}

class _ClientConnection {
  final Socket _socket;
  final AcpServer _server;
  final StreamController<List<int>> _controller = StreamController();
  StreamSubscription? _subscription;

  _ClientConnection(this._socket, this._server) {
    _socket.listen(_controller.add, onError: _controller.addError, onDone: _controller.close);
  }

  void start() {
    _subscription = _controller.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _socket.close();
    _server._removeClient(this);
  }

  void send(List<int> data) {
    _socket.add(data);
  }

  void sendResponse(AcpResponse response) {
    final json = jsonEncode({
      'jsonrpc': '2.0',
      'id': response.id,
      if (response.error != null) 'error': {
        'code': response.error!.code,
        'message': response.error!.message,
        if (response.error!.data != null) 'data': response.error!.data,
      } else 'result': response.result,
    });
    send(utf8.encode('$json\n'));
  }

  Future<void> _onData(List<int> data) async {
    final buffer = utf8.decode(data);
    final lines = buffer.split('\n');

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;

        if (json.containsKey('method') && !json.containsKey('id')) {
          final notification = AcpNotification.fromJson(json);
          _server._onNotification?.call(notification);
        } else if (json.containsKey('id')) {
          final request = AcpRequest(
            method: json['method'] as String,
            params: json['params'],
            id: json['id'] as int,
          );
          await _server._handleRequest(this, request);
        }
      } catch (e) {
        // Ignore parse errors
      }
    }
  }

  void _onError(Object error) {
    close();
  }

  void _onDone() {
    close();
  }
}