import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:utopic/src/acp/acp_client.dart';
import 'package:utopic/src/acp/acp_server.dart';
import 'package:utopic/src/acp/acp_types.dart';
import 'package:utopic/src/config/app_config.dart';
import 'package:utopic/src/services/ai_service.dart';
import 'package:utopic/src/services/agent_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Connects via TCP and wraps the socket with line-delimited JSON-RPC
/// messaging.  Supports multiple sequential [send] calls over the same
/// connection.
class _JsonRpcClient {
  final Socket _socket;
  late final StreamSubscription<List<int>> _subscription;
  final _pending = <Completer<Map<String, dynamic>>>[];
  String _buffer = '';

  _JsonRpcClient(this._socket) {
    _subscription = _socket.listen(
      (data) {
        _buffer += utf8.decode(data);
        while (_buffer.contains('\n')) {
          final idx = _buffer.indexOf('\n');
          final line = _buffer.substring(0, idx);
          _buffer = _buffer.substring(idx + 1);
          if (line.trim().isNotEmpty) {
            try {
              final json = jsonDecode(line) as Map<String, dynamic>;
              if (_pending.isNotEmpty) {
                final completer = _pending.removeAt(0);
                if (!completer.isCompleted) completer.complete(json);
              }
            } catch (_) {
              // non-JSON line – ignore
            }
          }
        }
      },
      onError: (e) {
        for (final c in _pending) {
          if (!c.isCompleted) c.completeError(e);
        }
        _pending.clear();
      },
      onDone: () {
        for (final c in _pending) {
          if (!c.isCompleted) {
            c.completeError(Exception('Socket closed'));
          }
        }
        _pending.clear();
      },
      cancelOnError: false,
    );
  }

  /// Send a JSON-RPC request and return the response.
  Future<Map<String, dynamic>> send(Map<String, dynamic> request) async {
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    _socket.write('${jsonEncode(request)}\n');
    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('No response within 3s'),
    );
  }

  /// Fire-and-forget: write JSON to the socket without awaiting a reply.
  void sendOnly(Map<String, dynamic> request) {
    _socket.write('${jsonEncode(request)}\n');
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

Future<_JsonRpcClient> _connect(int port) async {
  final socket = await Socket.connect('127.0.0.1', port)
      .timeout(const Duration(seconds: 2));
  return _JsonRpcClient(socket);
}

/// A mock HTTP client that returns pre-configured JSON responses.
class _MockHttpClient extends http.BaseClient {
  final _responses = <String, _MockResponse>{};
  final _requests = <http.BaseRequest>[];

  void addResponse(String url, int statusCode, Map<String, dynamic> body) {
    _responses[url] = _MockResponse(statusCode, body);
  }

  List<http.BaseRequest> get requests => List.unmodifiable(_requests);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _requests.add(request);
    final url = request.url.toString();
    final response = _responses[url];
    if (response != null) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(response.body))),
        response.statusCode,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":"not mocked"}')),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}

class _MockResponse {
  final int statusCode;
  final Map<String, dynamic> body;
  _MockResponse(this.statusCode, this.body);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ==========================================================================
  // ACP Types – unit tests for JSON-RPC 2.0 serialisation
  // ==========================================================================
  group('ACP Types', () {
    group('AcpRequest', () {
      test('toJson produces valid JSON-RPC 2.0 request', () {
        final req = AcpRequest(
          method: 'test.method',
          params: {'key': 'value'},
          id: 42,
        );
        expect(req.toJson(), {
          'jsonrpc': '2.0',
          'method': 'test.method',
          'params': {'key': 'value'},
          'id': 42,
        });
      });

      test('toJson omits params when null', () {
        final req = AcpRequest(method: 'ping', id: 1);
        expect(req.toJson(), {
          'jsonrpc': '2.0',
          'method': 'ping',
          'id': 1,
        });
      });

      test('toJsonString returns valid JSON', () {
        final req = AcpRequest(method: 'm', id: 1);
        final parsed = jsonDecode(req.toJsonString()) as Map<String, dynamic>;
        expect(parsed['method'], 'm');
        expect(parsed['id'], 1);
        expect(parsed['jsonrpc'], '2.0');
      });
    });

    group('AcpResponse', () {
      test('fromJson with result', () {
        final json = {'id': 1, 'result': 'hello'};
        final resp = AcpResponse.fromJson(json);
        expect(resp.id, 1);
        expect(resp.result, 'hello');
        expect(resp.isError, isFalse);
        expect(resp.error, isNull);
      });

      test('fromJson with result object', () {
        final json = {'id': 1, 'result': {'ok': true, 'count': 3}};
        final resp = AcpResponse.fromJson(json);
        expect(resp.id, 1);
        expect(resp.result, {'ok': true, 'count': 3});
        expect(resp.isError, isFalse);
      });

      test('fromJson with error', () {
        final json = {
          'id': 1,
          'error': {'code': -32601, 'message': 'Method not found'},
        };
        final resp = AcpResponse.fromJson(json);
        expect(resp.id, 1);
        expect(resp.isError, isTrue);
        expect(resp.error, isNotNull);
        expect(resp.error!.code, -32601);
        expect(resp.error!.message, 'Method not found');
        expect(resp.error!.data, isNull);
        expect(resp.result, isNull);
      });

      test('fromJson with error and data', () {
        final json = {
          'id': 1,
          'error': {
            'code': -32603,
            'message': 'Internal error',
            'data': {'detail': 'something broke'},
          },
        };
        final resp = AcpResponse.fromJson(json);
        expect(resp.isError, isTrue);
        expect(resp.error!.code, -32603);
        expect(resp.error!.data, {'detail': 'something broke'});
      });
    });

    group('AcpError', () {
      test('fromJson', () {
        final json = {
          'code': -32700,
          'message': 'Parse error',
          'data': null,
        };
        final err = AcpError.fromJson(json);
        expect(err.code, -32700);
        expect(err.message, 'Parse error');
        expect(err.data, isNull);
      });
    });

    group('AcpNotification', () {
      test('toJson with params', () {
        final n = AcpNotification(method: 'event', params: {'data': 1});
        expect(n.toJson(), {
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'data': 1},
        });
      });

      test('toJson omits params when null', () {
        final n = AcpNotification(method: 'ping');
        expect(n.toJson(), {
          'jsonrpc': '2.0',
          'method': 'ping',
        });
      });

      test('fromJson', () {
        final json = {
          'jsonrpc': '2.0',
          'method': 'update',
          'params': {'status': 'ok'},
        };
        final n = AcpNotification.fromJson(json);
        expect(n.method, 'update');
        expect(n.params, {'status': 'ok'});
      });
    });

    group('AcpSession', () {
      test('fromJson with all fields', () {
        final json = {
          'id': 'sess_1',
          'agent_id': 'default',
          'cwd': '/home/user',
          'metadata': {'foo': 'bar'},
        };
        final s = AcpSession.fromJson(json);
        expect(s.id, 'sess_1');
        expect(s.agentId, 'default');
        expect(s.cwd, '/home/user');
        expect(s.metadata, {'foo': 'bar'});
      });

      test('fromJson with missing metadata defaults to empty', () {
        final json = {
          'id': 'sess_2',
          'agent_id': 'agent-x',
          'cwd': '/tmp',
        };
        final s = AcpSession.fromJson(json);
        expect(s.id, 'sess_2');
        expect(s.metadata, {});
      });
    });

    group('AcpMethods', () {
      test('contains expected standard methods', () {
        expect(AcpMethods.initialize, 'initialize');
        expect(AcpMethods.shutdown, 'shutdown');
        expect(AcpMethods.sessionCreate, 'session/create');
        expect(AcpMethods.sessionDelete, 'session/delete');
        expect(AcpMethods.sessionList, 'session/list');
        expect(AcpMethods.agentRun, 'agent/run');
        expect(AcpMethods.agentCancel, 'agent/cancel');
        expect(AcpMethods.agentPause, 'agent/pause');
        expect(AcpMethods.agentResume, 'agent/resume');
        expect(AcpMethods.fsRead, 'fs/read');
        expect(AcpMethods.fsWrite, 'fs/write');
        expect(AcpMethods.fsList, 'fs/list');
        expect(AcpMethods.fsGlob, 'fs/glob');
        expect(AcpMethods.fsGrep, 'fs/grep');
        expect(AcpMethods.terminalCreate, 'terminal/create');
        expect(AcpMethods.terminalWrite, 'terminal/write');
        expect(AcpMethods.terminalKill, 'terminal/kill');
        expect(AcpMethods.terminalWait, 'terminal/wait');
        expect(AcpMethods.terminalResize, 'terminal/resize');
        expect(AcpMethods.terminalRun, 'terminal/run');
      });
    });

    group('AcpInitializeResult', () {
      test('fromJson', () {
        final json = {
          'server_name': 'utopic-agent',
          'server_version': '1.0.0',
          'capabilities': ['agent/run', 'session/manage'],
          'agent_info': {'model': 'deepseek-v4-flash-free'},
        };
        final r = AcpInitializeResult.fromJson(json);
        expect(r.serverName, 'utopic-agent');
        expect(r.serverVersion, '1.0.0');
        expect(r.capabilities, ['agent/run', 'session/manage']);
        expect(r.agentInfo, {'model': 'deepseek-v4-flash-free'});
      });
    });

    group('AcpAgentRunResult', () {
      test('fromJson', () {
        final json = {
          'session_id': 'sess_1',
          'status': 'completed',
          'output': 'Hello',
        };
        final r = AcpAgentRunResult.fromJson(json);
        expect(r.sessionId, 'sess_1');
        expect(r.status, 'completed');
        expect(r.output, 'Hello');
      });
    });
  });

  // ==========================================================================
  // AcpServer – protocol-level tests
  // ==========================================================================
  group('AcpServer', () {
    late AcpServer server;
    late int port;
    final receivedNotifications = <AcpNotification>[];

    setUp(() async {
      receivedNotifications.clear();
      server = AcpServer(host: '127.0.0.1', port: 0);

      // Handlers used across tests
      server.registerHandler('echo', (req) async => req.params);
      server.registerHandler('greet', (req) async {
        final p = req.params as Map<String, dynamic>? ?? {};
        return 'Hello, ${p['name'] ?? 'world'}!';
      });
      server.registerHandler('fail', (req) async {
        throw ArgumentError('intentional failure');
      });
      server.registerHandler('add', (req) async {
        final p = req.params as Map<String, dynamic>;
        return (p['a'] as int) + (p['b'] as int);
      });
      server.registerHandler('null-result', (req) async => null);
      server.registerHandler('slow', (req) async {
        await Future.delayed(const Duration(milliseconds: 150));
        return 'slow response';
      });

      server.setNotificationHandler((notification) {
        receivedNotifications.add(notification);
      });

      await server.start();
      port = server.boundPort!;
      expect(port, greaterThan(0));
    });

    tearDown(() async {
      await server.stop();
    });

    // -- Lifecycle ----------------------------------------------------------

    test('server is running after start', () {
      expect(server.isRunning, isTrue);
    });

    test('server is not running after stop', () async {
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('start is idempotent', () async {
      await server.start(); // already started in setUp
      expect(server.isRunning, isTrue);
    });

    test('stop is idempotent when not running', () async {
      final s = AcpServer(host: '127.0.0.1', port: 0);
      // Should not throw
      await s.stop();
      expect(s.isRunning, isFalse);
    });

    // -- Basic request/response ---------------------------------------------

    test('registered handler returns result', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'echo',
        'params': {'x': 1, 'y': 2},
        'id': 1,
      });
      await client.close();

      expect(resp['id'], 1);
      expect(resp['result'], {'x': 1, 'y': 2});
      expect(resp.containsKey('error'), isFalse);
    });

    test('handler returning string works', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'greet',
        'params': {'name': 'Utopic'},
        'id': 2,
      });
      await client.close();

      expect(resp['id'], 2);
      expect(resp['result'], 'Hello, Utopic!');
    });

    test('handler with default params works', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'greet',
        'params': {},
        'id': 3,
      });
      await client.close();

      expect(resp['result'], 'Hello, world!');
    });

    test('handler returning null works', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'null-result',
        'id': 4,
      });
      await client.close();

      expect(resp['result'], isNull);
    });

    // -- Error handling -----------------------------------------------------

    test('unknown method returns -32601 Method Not Found', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'nonexistent',
        'params': {},
        'id': 99,
      });
      await client.close();

      expect(resp['id'], 99);
      expect(resp['error'], isNotNull);
      expect(resp['error']['code'], -32601);
      expect(resp['error']['message'], contains('nonexistent'));
    });

    test('handler exception returns -32603 Internal Error', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'fail',
        'params': {},
        'id': 100,
      });
      await client.close();

      expect(resp['id'], 100);
      expect(resp['error'], isNotNull);
      expect(resp['error']['code'], -32603);
      expect(resp['error']['message'], contains('intentional failure'));
    });

    // -- Notifications ------------------------------------------------------

    test('notification is delivered without response', () async {
      final client = await _connect(port);
      // Send a notification (no id) — fire-and-forget
      client.sendOnly({
        'jsonrpc': '2.0',
        'method': 'notify-test',
        'params': {'event': 'user_login'},
      });
      await Future.delayed(const Duration(milliseconds: 150));
      await client.close();

      expect(receivedNotifications.length, greaterThanOrEqualTo(1));
      final last = receivedNotifications.last;
      expect(last.method, 'notify-test');
      expect(last.params, {'event': 'user_login'});
    });

    test('multiple notifications accumulate', () async {
      final client = await _connect(port);
      for (int i = 0; i < 3; i++) {
        client.sendOnly({
          'jsonrpc': '2.0',
          'method': 'multi-notify',
          'params': {'seq': i},
        });
      }
      await Future.delayed(const Duration(milliseconds: 150));
      await client.close();

      expect(receivedNotifications.length, greaterThanOrEqualTo(3));
      expect(receivedNotifications.last.method, 'multi-notify');
    });

    // -- Edge cases ---------------------------------------------------------

    test('invalid JSON fields are silently ignored (no crash)', () async {
      final client = await _connect(port);
      // Send a JSON object that doesn't conform to JSON-RPC but is valid JSON
      client.sendOnly({'this': 'is valid json but not json-rpc'});
      await Future.delayed(const Duration(milliseconds: 50));

      // Following valid request should still work
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'echo',
        'params': {'ok': true},
        'id': 10,
      });
      await client.close();

      expect(resp['id'], 10);
      expect(resp['result'], {'ok': true});
    });

    test('multiple concurrent clients work', () async {
      final clients = <_JsonRpcClient>[];
      final futures = <Future<Map<String, dynamic>>>[];

      for (int i = 0; i < 5; i++) {
        final client = await _connect(port);
        clients.add(client);
        futures.add(client.send({
          'jsonrpc': '2.0',
          'method': 'add',
          'params': {'a': i, 'b': i * 10},
          'id': 100 + i,
        }));
      }

      final results = await Future.wait(futures);

      for (int i = 0; i < 5; i++) {
        expect(results[i]['id'], 100 + i);
        expect(results[i]['result'], i + i * 10);
      }

      for (final c in clients) {
        await c.close();
      }
    });

    test('slow handler eventually responds', () async {
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'slow',
        'id': 200,
      });
      await client.close();

      expect(resp['id'], 200);
      expect(resp['result'], 'slow response');
    });
  });

  // ==========================================================================
  // AgentService ACP Integration
  // ==========================================================================
  group('ACP Integration', () {
    late _MockHttpClient mockHttp;
    late AppConfig config;
    late AiService aiService;
    late AgentService agentService;

    setUp(() async {
      mockHttp = _MockHttpClient();

      // Mock the models endpoint called by initialize()
      mockHttp.addResponse(
        'https://opencode.ai/zen/v1/models',
        200,
        {'data': [{'id': 'test-model'}]},
      );

      config = AppConfig(
        opencodeApiKey: 'test-key',
        defaultModel: 'test-model',
        zenEndpoint: 'https://opencode.ai/zen',
        acp: AcpConfig(
          host: '127.0.0.1',
          port: 0, // random port for tests
          socketPath: '',
        ),
      );

      aiService = ZenAiService(config: config, client: mockHttp);
      agentService = AgentService(config: config, aiService: aiService);
      await agentService.initialize();
    });

    tearDown(() async {
      await agentService.stopAcpServer();
    });

    test('initialize returns server info with capabilities', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      expect(agentService.isAcpRunning, isTrue);

      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'id': 1,
      });
      await client.close();

      expect(resp['id'], 1);
      expect(resp['result'], isNotNull);
      expect(resp['result']['server_name'], 'utopic-agent');
      expect(resp['result']['server_version'], '1.0.0');
      expect(resp['result']['capabilities'], isA<List>());
      expect(resp['result']['capabilities'], contains('agent/run'));
      expect(resp['result']['capabilities'], contains('session/create'));
      expect(resp['result']['capabilities'], contains('session/list'));
      expect(resp['result']['capabilities'], contains('session/delete'));
      expect(resp['result']['agent_info'], isA<Map>());
    });

    test('session/create returns a session', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'session/create',
        'params': {
          'agent_id': 'default',
          'cwd': '/tmp',
          'metadata': {'env': 'test'},
        },
        'id': 2,
      });
      await client.close();

      expect(resp['id'], 2);
      expect(resp['result'], isNotNull);
      expect(resp['result']['id'], startsWith('session_'));
      expect(resp['result']['agent_id'], 'default');
      expect(resp['result']['cwd'], '/tmp');
      expect(resp['result']['metadata'], {'env': 'test'});
    });

    test('session/create with defaults', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'session/create',
        'params': {},
        'id': 3,
      });
      await client.close();

      expect(resp['result']['agent_id'], 'default');
      expect(resp['result']['cwd'], isNot(isEmpty));
      expect(resp['result']['metadata'], {});
    });

    test('session/list returns conversations', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'session/list',
        'id': 4,
      });
      await client.close();

      expect(resp['id'], 4);
      expect(resp['result'], isA<List>());
      expect(resp['result'], isNotEmpty);
      expect(resp['result'][0]['id'], isNotNull);
      expect(resp['result'][0]['title'], 'Welcome to Utopic Agent');
      expect(resp['result'][0]['message_count'], greaterThan(0));
      expect(resp['result'][0]['updated_at'], isNotNull);
    });

    test('session/delete acknowledges', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'session/delete',
        'params': {'id': 'sess_1'},
        'id': 5,
      });
      await client.close();

      expect(resp['result'], {'deleted': true});
    });

    test('agent/run processes a prompt and returns output', () async {
      // Mock the Zen API responses endpoint
      mockHttp.addResponse(
        'https://opencode.ai/zen/v1/responses',
        200,
        {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Hello from Utopic!'},
              ],
            },
          ],
          'model': 'test-model',
          'usage': {'input_tokens': 10, 'output_tokens': 5},
        },
      );

      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'agent/run',
        'params': {
          'prompt': 'Say hello',
          'session_id': null,
        },
        'id': 6,
      });
      await client.close();

      expect(resp['id'], 6);
      expect(resp['result'], isNotNull);
      expect(resp['result']['status'], 'completed');
      expect(resp['result']['output'], 'Hello from Utopic!');
      expect(resp['result']['session_id'], isNotNull);
      expect(resp['result']['usage'], isNotNull);
      expect(resp['result']['usage']['input_tokens'], 10);
      expect(resp['result']['usage']['output_tokens'], 5);
    });

    test('agent/run works without session_id', () async {
      mockHttp.addResponse(
        'https://opencode.ai/zen/v1/responses',
        200,
        {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'No session needed'},
              ],
            },
          ],
          'model': 'test-model',
          'usage': {'input_tokens': 5, 'output_tokens': 3},
        },
      );

      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'agent/run',
        'params': {'prompt': 'Hi'},
        'id': 7,
      });
      await client.close();

      expect(resp['result']['status'], 'completed');
      expect(resp['result']['output'], 'No session needed');
    });

    test('agent/cancel acknowledges', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'agent/cancel',
        'params': {},
        'id': 8,
      });
      await client.close();

      expect(resp['result'], {'cancelled': true});
    });

    test('ACP server lifecycle: start, stop, restart', () async {
      expect(agentService.isAcpRunning, isFalse);

      await agentService.startAcpServer();
      expect(agentService.isAcpRunning, isTrue);

      await agentService.stopAcpServer();
      expect(agentService.isAcpRunning, isFalse);

      await agentService.startAcpServer();
      expect(agentService.isAcpRunning, isTrue);

      // Verify it works after restart
      final port = agentService.acpPort!;
      final client = await _connect(port);
      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'id': 9,
      });
      await client.close();

      expect(resp['result']['server_name'], 'utopic-agent');
    });

    test('fs/read returns file content', () async {
      // Write a temp file to read
      final tmp = File('/tmp/acp_test_read.txt');
      await tmp.writeAsString('hello from acp');

      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'fs/read',
        'params': {'path': '/tmp/acp_test_read.txt'},
        'id': 100,
      });
      await client.close();
      await tmp.delete();

      expect(resp['id'], 100);
      expect(resp['result']['content'], 'hello from acp');
    });

    test('fs/write creates a file', () async {
      final tmp = File('/tmp/acp_test_write.txt');
      if (await tmp.exists()) await tmp.delete();

      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'fs/write',
        'params': {'path': '/tmp/acp_test_write.txt', 'content': 'written via acp'},
        'id': 101,
      });
      await client.close();

      final written = await tmp.readAsString();
      await tmp.delete();

      expect(resp['id'], 101);
      expect(resp['result']['success'], isTrue);
      expect(written, 'written via acp');
    });

    test('fs/list returns directory entries', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'fs/list',
        'params': {'path': '/tmp'},
        'id': 102,
      });
      await client.close();

      expect(resp['id'], 102);
      expect(resp['result']['entries'], isA<List>());
      expect(resp['result']['entries'], isNotEmpty);
      expect(resp['result']['entries'][0]['name'], isA<String>());
      expect(resp['result']['entries'][0]['type'], anyOf('file', 'directory'));
    });

    test('terminal/run executes a command', () async {
      await agentService.startAcpServer();
      await Future.delayed(const Duration(milliseconds: 50));
      final port = agentService.acpPort!;
      final client = await _connect(port);

      final resp = await client.send({
        'jsonrpc': '2.0',
        'method': 'terminal/run',
        'params': {'command': 'echo "hello from acp"', 'timeout': 5},
        'id': 103,
      });
      await client.close();

      expect(resp['id'], 103);
      expect(resp['result']['stdout'], contains('hello from acp'));
      expect(resp['result']['exit_code'], 0);
    });
  });

  // ==========================================================================
  // AcpClient – client-side tests
  // ==========================================================================
  group('AcpClient', () {
    late AcpServer server;
    late int port;

    setUp(() async {
      server = AcpServer(host: '127.0.0.1', port: 0);
      server.registerHandler('initialize', (req) async {
        return {
          'server_name': 'test-server',
          'server_version': '1.0.0',
          'capabilities': ['agent/run'],
          'agent_info': {'model': 'test-model', 'provider': 'test'},
        };
      });
      server.registerHandler('test.echo', (req) async {
        return req.params as Map<String, dynamic>? ?? {};
      });
      server.registerHandler('test.error', (req) async {
        throw Exception('intentional error');
      });
      await server.start();
      port = server.boundPort!;
    });

    tearDown(() async {
      await server.stop();
    });

    test('connect and initialize', () async {
      final client = TcpAcpClient(host: '127.0.0.1', port: port);
      final info = await client.connect();
      await client.close();

      expect(info, isNotEmpty);
      expect(client.isConnected, isFalse);
    });

    test('call a registered handler', () async {
      final client = TcpAcpClient(host: '127.0.0.1', port: port);
      await client.connect();

      final result = await client.call('test.echo', params: {'msg': 'hello'});
      await client.close();

      expect(result['msg'], 'hello');
    });

    test('call throws on remote error', () async {
      final client = TcpAcpClient(host: '127.0.0.1', port: port);
      await client.connect();

      await expectLater(
        client.call('test.error'),
        throwsA(isA<AcpClientException>()),
      );
      await client.close();
    });

    test('call throws on unknown method', () async {
      final client = TcpAcpClient(host: '127.0.0.1', port: port);
      await client.connect();

      await expectLater(
        client.call('nonexistent.method'),
        throwsA(isA<AcpClientException>()),
      );
      await client.close();
    });

    test('serverInfo is populated after connect', () async {
      final client = TcpAcpClient(host: '127.0.0.1', port: port);

      // Before connect, no server info
      expect(client.serverInfo, isNull);

      await client.connect();
      expect(client.serverInfo, isNotNull);
      await client.close();
    });
  });

  // ==========================================================================
  // StdioAcpClient – subprocess (stdin/stdout) transport
  // ==========================================================================
  group('StdioAcpClient', () {
    test('connect and initialize', () async {
      final client = StdioAcpClient(
        command: 'dart',
        arguments: ['run', 'test/helpers/acp_echo.dart'],
      );
      final info = await client.connect();

      expect(info['server_name'], 'test-stdio-server');
      expect(info['agent_info']['model'], 'test-stdio-model');
      expect(client.label, contains('cli:'));

      await client.close();
    });

    test('call echo handler', () async {
      final client = StdioAcpClient(
        command: 'dart',
        arguments: ['run', 'test/helpers/acp_echo.dart'],
      );
      await client.connect();

      final result = await client.call('test.echo', params: {'msg': 'yo'});
      expect(result['msg'], 'yo');

      await client.close();
    });

    test('call throws on error', () async {
      final client = StdioAcpClient(
        command: 'dart',
        arguments: ['run', 'test/helpers/acp_echo.dart'],
      );
      await client.connect();

      await expectLater(
        client.call('test.error'),
        throwsA(isA<AcpClientException>()),
      );

      await client.close();
    });

    test('call throws on unknown method', () async {
      final client = StdioAcpClient(
        command: 'dart',
        arguments: ['run', 'test/helpers/acp_echo.dart'],
      );
      await client.connect();

      await expectLater(
        client.call('nope.not.a.method'),
        throwsA(isA<AcpClientException>()),
      );

      await client.close();
    });

    test('connect fails fast on non-ACP process', () async {
      // 'true' exits immediately — should surface exit code, not hang.
      final client = StdioAcpClient(command: 'true');
      await expectLater(
        client.connect(),
        throwsA(predicate((e) =>
            e is Exception &&
            e.toString().contains('Subprocess exited with code 0'))),
      );
      await client.close();
    });
  });
}
