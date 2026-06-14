import 'dart:convert';
import 'dart:io';
import 'package:utopic/utopic.dart';

void main() async {
  final config = AppConfig.defaultConfig();
  final agent = AgentService(config: config);

  // init without triggering initialize()
  agent.initialize().catchError((e) => print('Init error: $e'));
  
  // Wait for init
  await Future.delayed(Duration(milliseconds: 500));

  // Start ACP server
  print('Starting ACP server...');
  await agent.startAcpServer();
  print('ACP server running: ${agent.isAcpRunning}, port: ${agent.acpPort}');

  if (!agent.isAcpRunning) {
    print('FAIL: server not running');
    exit(1);
  }

  // Connect with raw TCP
  final socket = await Socket.connect('127.0.0.1', agent.acpPort!);
  print('Connected to port ${agent.acpPort}');

  // Read responses
  socket.listen((data) {
    print('RESPONSE: ${utf8.decode(data)}');
  });

  // Wait for listener
  await Future.delayed(Duration(milliseconds: 100));

  // Send initialize
  socket.write('{"jsonrpc":"2.0","id":1,"method":"initialize"}\n');
  print('Sent initialize');

  await Future.delayed(Duration(milliseconds: 500));

  // Send session/create
  socket.write('{"jsonrpc":"2.0","id":2,"method":"session/create","params":{"agent_id":"paseo"}}\n');
  print('Sent session/create');

  await Future.delayed(Duration(milliseconds: 500));

  // Send agent/run
  socket.write('{"jsonrpc":"2.0","id":3,"method":"agent/run","params":{"prompt":"hello world"}}\n');
  print('Sent agent/run (this might take a while)');

  await Future.delayed(Duration(seconds: 5));

  await agent.stopAcpServer();
  await socket.close();
  print('Done');
}
