import 'dart:convert';
import 'dart:io';
import 'package:utopic/src/acp/acp_server.dart';

void main() async {
  final server = AcpServer(host: '127.0.0.1', port: 0);
  
  server.registerHandler('initialize', (request) async {
    print('HANDLER: initialize called id=${request.id} (${request.id.runtimeType})');
    return {
      'server_name': 'utopic-test',
      'server_version': '1.0.0',
      'capabilities': ['initialize', 'agent/run'],
    };
  });

  await server.start();
  final port = server.boundPort!;
  print('Server bound to port $port');

  // Connect with raw TCP
  final socket = await Socket.connect('127.0.0.1', port);
  print('Connected');

  // Read responses in background
  socket.listen((data) {
    print('SOCKET RECV: ${utf8.decode(data)}');
  });

  // Wait a tick for listener to attach
  await Future.delayed(Duration(milliseconds: 100));

  // Test 1: \n line ending
  socket.write('{"jsonrpc":"2.0","id":1,"method":"initialize"}\n');
  print('Test 1: sent initialize (\\n)');

  await Future.delayed(Duration(milliseconds: 300));

  // Test 2: \r\n line ending
  socket.write('{"jsonrpc":"2.0","id":2,"method":"initialize"}\r\n');
  print('Test 2: sent initialize (\\r\\n)');

  await Future.delayed(Duration(milliseconds: 300));

  // Test 3: string ID
  socket.write('{"jsonrpc":"2.0","id":"hello-id","method":"initialize"}\n');
  print('Test 3: sent initialize (string id)');

  await Future.delayed(Duration(milliseconds: 300));

  // Test 4: both requests in one packet
  socket.write('{"jsonrpc":"2.0","id":4,"method":"initialize"}\n{"jsonrpc":"2.0","id":5,"method":"initialize"}\n');
  print('Test 4: sent two requests in one packet');

  await Future.delayed(Duration(milliseconds: 300));

  // Test 5: method not found
  socket.write('{"jsonrpc":"2.0","id":6,"method":"unknown.method"}\n');
  print('Test 5: sent unknown method');

  await Future.delayed(Duration(milliseconds: 300));

  await server.stop();
  await socket.close();
  print('All done');
}
