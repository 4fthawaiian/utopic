import 'dart:async';
import 'dart:io';
import 'tool.dart';

class BashTool extends Tool {
  @override
  String get name => 'bash';

  @override
  String get description => 'Execute a bash command. Returns stdout and stderr. '
      'Use this for running terminal commands, scripts, and inspecting the system.';

  @override
  List<String> get required => ['command'];

  @override
  Map<String, dynamic> get parameters => {
    'command': {
      'type': 'string',
      'description': 'The bash command to execute',
    },
    'timeout': {
      'type': 'number',
      'description': 'Timeout in seconds (optional, default 30)',
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final cmd = args['command'] as String? ?? '';
    if (cmd.isEmpty) return 'Error: command is required';

    final timeoutSec = (args['timeout'] as num?)?.toInt() ?? 30;

    try {
      final result = await Process.run(
        'bash',
        ['-c', cmd],
        runInShell: true,
      ).timeout(Duration(seconds: timeoutSec));

      final output = <String>[];
      if (result.stdout.toString().trim().isNotEmpty) {
        output.add(result.stdout.toString().trim());
      }
      if (result.stderr.toString().trim().isNotEmpty) {
        output.add('--- stderr ---\n${result.stderr.toString().trim()}');
      }
      if (result.exitCode != 0) {
        output.insert(0, 'Exit code: ${result.exitCode}');
      }
      final joined = output.join('\n');
      return joined.isNotEmpty ? joined : '(no output)';
    } on TimeoutException {
      return 'Error: command timed out after ${timeoutSec}s';
    } catch (e) {
      return 'Error: $e';
    }
  }
}
