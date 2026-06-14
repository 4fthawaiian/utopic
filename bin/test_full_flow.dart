import 'dart:convert';
import 'dart:io';
import 'package:utopic/src/acp/acp_dart_client.dart';

/// Test exactly what the TUI does when /acp-connect cli:devin acp is run
Future<void> main() async {
  // Simulate the TUI command parsing
  final cmdStr = 'cli:devin acp';
  final parts = 'acp-connect ${cmdStr}'.split(RegExp(r'\s+'));
  
  stdout.writeln('parts: $parts');
  stdout.writeln('parts[1]: ${parts[1]}');
  stdout.writeln('startsWith cli:: ${parts[1].startsWith('cli:')}');
  
  final cmd = parts[1].substring(4);  // 'devin'
  final args = parts.length > 2 ? parts.sublist(2) : <String>[];  // ['acp']
  
  stdout.writeln('cmd: $cmd');
  stdout.writeln('args: $args');
  
  // Now do exactly what connectToAcpCli does
  final conn = AcpDartConnection();
  
  try {
    stdout.writeln('');
    stdout.writeln('=== Calling connectToCli ===');
    await conn.connectToCli(cmd, args);
    stdout.writeln('connectToCli DONE');
    
    stdout.writeln('');
    stdout.writeln('=== Calling createSession ===');
    await conn.createSession();
    stdout.writeln('createSession DONE');
    
    stdout.writeln('');
    stdout.writeln('Server name: ${conn.serverName}');
    stdout.writeln('Current model ID: ${conn.currentModelId}');
    stdout.writeln('Available models: ${conn.availableModels.length}');
    
    stdout.writeln('');
    stdout.writeln('=== _swapToAcp equivalent ===');
    // This is what AcpAiService receives
    stdout.writeln('Server info agentInfo?.name: ${conn.serverInfo?.agentInfo?.name}');
    stdout.writeln('Server info agentInfo?.title: ${conn.serverInfo?.agentInfo?.title}');
    stdout.writeln('Server info agentInfo?.version: ${conn.serverInfo?.agentInfo?.version}');
    
    stdout.writeln('');
    stdout.writeln('=== Return value for TUI ===');
    final info = {
      'server_name': conn.serverName,
      'agent_info': {'model': conn.currentModelId ?? 'unknown'},
    };
    stdout.writeln('info: $info');
    
    await conn.disconnect();
    stdout.writeln('');
    stdout.writeln('SUCCESS!');
  } catch (e) {
    stderr.writeln('FAILED: $e');
    stderr.writeln('${e.runtimeType}');
    await conn.disconnect();
    exitCode = 1;
  }
}
