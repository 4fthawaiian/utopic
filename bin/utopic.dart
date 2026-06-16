import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:utopic/utopic.dart';
import 'package:utopic/src/services/tools/tools.dart';
import 'package:utopic/src/vendor/runner.dart';

void main(List<String> args) async {
  String? promptFile;
  String? configPath;
  String? loadSessionId;
  var phobeMode = false;
  final positional = <String>[];

  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--help' || args[i] == '-h') {
      print(helpText);
      return;
    }
    if (args[i] == '--prompt' && i + 1 < args.length) {
      promptFile = args[++i];
      continue;
    }
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
      continue;
    }
    if (args[i] == '--load' && i + 1 < args.length) {
      loadSessionId = args[++i];
      continue;
    }
    if (args[i] == '--phobe') {
      phobeMode = true;
      continue;
    }
    if (args[i] == '--acp-server') {
      // Handled below after config load
      continue;
    }
    if (args[i] == '--acp-stdio') {
      // Handled below after config load
      continue;
    }
    if (args[i].startsWith('--')) {
      stderr.writeln('Unknown option: ${args[i]}');
      exit(1);
    }
    positional.add(args[i]);
  }

  final config = AppConfig.load(promptFile: promptFile, configPath: configPath);

  // One-shot mode: positional arg is the prompt string
  // e.g.  dart run -- "what's 2+2?"   or   ./utopic "refactor this"
  if (positional.isNotEmpty) {
    await _runOnce(positional.join(' '), config);
    return;
  }

  // ACP server mode: run headless, just serve ACP protocol
  if (args.contains('--acp-stdio')) {
    await _runAcpServer(config, stdio: true);
    return;
  }
  if (args.contains('--acp-server')) {
    await _runAcpServer(config);
    return;
  }

  // Interactive TUI mode
  final app = UtopicTuiApp(
    config: config,
    phobeMode: phobeMode,
    loadSessionId: loadSessionId,
  );
  final runner = UtopicRunner(app)
    ..onBeforeExit = () => app.printSessionSummary();
  await runner.run().catchError((e) {
    stderr.writeln('Fatal error: $e');
    exit(1);
  });
}

/// Run in ACP server mode — no TUI, just serve ACP protocol.
///
/// If [stdio] is true, reads/writes JSON-RPC on stdin/stdout instead of
/// listening on a TCP socket.
Future<void> _runAcpServer(AppConfig config, {bool stdio = false}) async {
  final agent = AgentService(config: config);
  await agent.initialize();

  if (stdio) {
    await agent.startAcpServer(stdio: true);
    stderr.writeln('ACP stdio server started on stdin/stdout');
    // Block until stdin closes (server handles protocol internally)
    await agent.acpServerDone;
  } else {
    await agent.startAcpServer();
    stdout.writeln('ACP server started on ${config.acp.host}:${config.acp.port}');
    stdout.writeln('Press Ctrl+C to stop...');

    final completer = Completer<void>();
    ProcessSignal.sigint.watch().listen((_) {
      if (!completer.isCompleted) {
        stdout.writeln('\nShutting down...');
        completer.complete();
      }
    });
    await completer.future;
  }

  await agent.stopAcpServer();
  stdout.writeln('ACP server stopped.');
}

/// Run a single prompt non-interactively and print the response.
Future<void> _runOnce(String prompt, AppConfig config) async {
  final systemPrompt = _buildSystemPrompt(config);

  final conv = Conversation(title: 'CLI Run');
  conv.addMessage(Message(role: 'system', content: systemPrompt));
  conv.addMessage(Message(role: 'user', content: prompt));

  final ai = ZenAiService(config: config);

  // Tool definitions
  final tools = [
    ReadTool(), BashTool(), EditTool(), WriteTool(),
  ].map((t) => t.toJson()).toList();

  const maxIterations = 10;

  try {
    for (var i = 0; i < maxIterations; i++) {
      final result = await ai.complete(
        conversation: conv,
        tools: tools,
      );

      if (result.hasToolCalls) {
        // Store tool call in conversation
        conv.addMessage(Message(
          role: 'assistant',
          content: '',
          toolCalls: result.toolCalls.map((tc) => {
            'id': tc.id,
            'name': tc.name,
            'arguments': jsonEncode(tc.arguments),
          }).toList(),
        ));

        // Execute tools
        for (final tc in result.toolCalls) {
          final output = await _executeTool(tc.name, tc.arguments, tools);
          conv.addMessage(Message(
            role: 'tool',
            content: output,
            toolCallId: tc.id,
          ));
        }
      } else {
        stdout.writeln(result.content);
        return;
      }
    }
    stderr.writeln('Reached max iterations.');
    exit(1);
  } catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }
}

Future<String> _executeTool(String name, Map<String, dynamic> args, List<Map<String, dynamic>> toolDefs) async {
  final tools = [ReadTool(), BashTool(), EditTool(), WriteTool()];
  for (final t in tools) {
    if (t.name == name) return await t.execute(args);
  }
  return 'Error: unknown tool "$name"';
}

/// Build system prompt from config, AGENTS.md, and --prompt file.
String _buildSystemPrompt(AppConfig config) {
  final parts = <String>[];

  if (config.systemPrompt != null && config.systemPrompt!.isNotEmpty) {
    parts.add(config.systemPrompt!);
  } else {
    parts.add(
      'You are Utopic, an AI coding agent running in a terminal. '
      'You are enthusiastic, queer-friendly, and love helping people build things. '
      'You have REAL access to bash, read, write, and edit tools — use them! '
      'When asked about files or to run commands, use the tools instead of guessing. '
      'Be enthusiastic and supportive — you are a fabulous coding companion!',
    );
  }

  // Local AGENTS.md (cwd)
  String? agentsContent;
  String? agentsLabel;
  for (final f in ['AGENTS.md', 'AGENT.md', 'agents.md', 'agent.md']) {
    final file = File(path.join(Directory.current.path, f));
    if (file.existsSync()) {
      agentsContent = file.readAsStringSync().trim();
      agentsLabel = '--- From $f ---';
      break;
    }
  }
  // Global AGENTS.md (~/.config/utopic/) as fallback
  if (agentsContent == null) {
    final home = Platform.environment['HOME'] ?? '';
    for (final f in ['AGENTS.md', 'AGENT.md', 'agents.md', 'agent.md']) {
      final file = File(path.join(home, '.config', 'utopic', f));
      if (file.existsSync()) {
        agentsContent = file.readAsStringSync().trim();
        agentsLabel = '--- From ~/.config/utopic/$f (global) ---';
        break;
      }
    }
  }
  if (agentsContent != null && agentsLabel != null) {
    parts.add('');
    parts.add(agentsLabel);
    parts.add(agentsContent);
  }

  if (config.promptFile != null && config.promptFile!.isNotEmpty) {
    final file = File(config.promptFile!);
    if (file.existsSync()) {
      parts.add('');
      parts.add('--- Instructions from ${config.promptFile} ---');
      parts.add(file.readAsStringSync().trim());
    }
  }

  return parts.join('\n');
}

String get helpText => '''
Utopic Agent - AI Coding Agent TUI

USAGE:
  utopic                         Start interactive TUI
  utopic "prompt text"           One-shot: send a prompt, print response, exit

OPTIONS:
  --config <path>  Path to config file
  --prompt <path>  Path to a prompt file (appended to system prompt)
  --load <id>      Resume a saved session by ID (see /save + exit message)
  --phobe          Launch in boring mode (no pride theming)
  --acp-server     Run in daemon mode (headless ACP server over TCP, no TUI)
  --acp-stdio      Run in daemon mode (headless ACP server over stdin/stdout)
  --help / -h      Show this help

CONFIG:
  The agent looks for config in order:
  1. \$UTOPIC_CONFIG environment variable
  2. ./utopic.yaml
  3. ~/.config/utopic/config.yaml
  4. ~/.utopic.yaml

ENVIRONMENT:
  OPENCODE_API_KEY  API key for OpenCode Zen models

KEYS (interactive mode):
  Enter           Send message
  ↑/↓             Scroll line up/down
  PgUp/PgDn       Scroll page up/down
  Home/End        Scroll to top/bottom
  ←/→             Move cursor in input
  type /command   Run a command (/help for list)
  Ctrl+D          Quit (like normal terminal EOF)
  Ctrl+C          Interrupt / cancel (passes through)

PRE-CONFIGURED MODELS (via OpenCode Zen):
  ${ZenModels.all.map((m) => '${m.id}${m.isFree ? ' (free)' : ''}').join('\n  ')}

ACP (Agent Client Protocol):
  Built-in ACP server for integration with other tools
  Default: tcp://127.0.0.1:${_defaultAcpPort()}
  --acp-server     Headless TCP server (use nc, telnet, etc.)
  --acp-stdio      Headless stdio server (Paseo, subprocess pipes)

SYSTEM PROMPT:
  Sources (merged in order):
    1. Default or system_prompt in utopic.yaml
    2. AGENTS.md in cwd, or ~/.config/utopic/AGENTS.md as fallback
    3. --prompt <file> (CLI flag)
    4. /prompt <text> (per-conversation override, TUI only)
''';

int _defaultAcpPort() {
  try {
    final config = AppConfig.load();
    return config.acp.port;
  } catch (_) {
    return 8080;
  }
}
