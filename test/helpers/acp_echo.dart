// Minimal ACP server over stdin/stdout for testing StdioAcpClient.
//
// Reads newline-delimited JSON-RPC 2.0 requests from stdin and writes
// responses to stdout.  Supports:
//   initialize   → returns server info
//   test.echo    → echoes params
//   test.error   → returns JSON-RPC error

import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final id = json['id'];
    final method = json['method'] as String?;

    if (id == null) return; // notification — ignore

    Map<String, dynamic> response;

    switch (method) {
      case 'initialize':
        response = {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'server_name': 'test-stdio-server',
            'server_version': '1.0.0',
            'capabilities': ['agent/run', 'test.echo'],
            'agent_info': {'model': 'test-stdio-model', 'provider': 'test'},
          },
        };
        break;

      case 'test.echo':
        response = {
          'jsonrpc': '2.0',
          'id': id,
          'result': json['params'] ?? {},
        };
        break;

      case 'test.error':
        response = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32000, 'message': 'intentional test error'},
        };
        break;

      default:
        response = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        };
    }

    stdout.writeln(jsonEncode(response));
  });
}