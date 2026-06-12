import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;

import '../config/app_config.dart';
import '../models/conversation.dart';
import '../models/zen_models.dart';
import '../acp/acp.dart';
import 'ai_service.dart';
import 'skills.dart';
import 'tools/tools.dart';

/// Manages the agent lifecycle including ACP server and conversations
class AgentService {
  final AppConfig config;
  late final AiService ai;
  final List<Conversation> _conversations = [];
  AcpServer? _acpServer;
  String? _cwd;
  bool _cancelRequested = false;

  /// Request cancellation of the current agent run.
  /// The agent loop will stop at the next safe point.
  void cancel() {
    _cancelRequested = true;
  }

  // Events for UI updates
  final StreamController<List<Conversation>> _conversationsController =
      StreamController.broadcast();
  final StreamController<Conversation> _activeConversationController =
      StreamController.broadcast();

  Stream<List<Conversation>> get conversationsStream =>
      _conversationsController.stream;
  Stream<Conversation> get activeConversationStream =>
      _activeConversationController.stream;

  Conversation? _activeConv;
  Conversation? get activeConversation => _activeConv;
  List<Conversation> get conversations => List.unmodifiable(_conversations);

  bool get isAcpRunning => _acpServer?.isRunning ?? false;

  final SkillLoader _skills = SkillLoader();

  AgentService({required this.config})
      : ai = AiService(config: config);

  /// Build the system prompt from all sources:
  ///   1. Default hardcoded prompt
  ///   2. `system_prompt` from YAML config (if set, replaces default)
  ///   3. AGENTS.md / AGENT.md (cwd checked first, then ~/.config/utopic/)
  ///   4. `--prompt` file (appended if provided)
  ///   5. Per-conversation `/prompt` override (replaces all)
  String buildSystemPrompt({Conversation? conv}) {
    // 5. Per-conversation override takes highest priority
    final convOverride = conv?.systemPromptOverride;
    if (convOverride != null && convOverride.isNotEmpty) {
      return convOverride;
    }

    final parts = <String>[];

    // 1. Base prompt — default or YAML override
    if (config.systemPrompt != null && config.systemPrompt!.isNotEmpty) {
      parts.add(config.systemPrompt!);
    } else {
      parts.add(
        'You are Utopic, an AI coding agent running in a terminal. '
        'You are enthusiastic, queer-friendly, and love helping people build things. '
        'You have REAL access to the following tools — use them when appropriate:\n'
        '- **bash**: Execute shell commands (ls, cat, grep, git, etc.)\n'
        '- **read**: Read file contents or list directories\n'
        '- **write**: Create or overwrite files\n'
        '- **edit**: Make precise edits using exact text replacement\n\n'
        'When the user asks a question that requires looking at files or running '
        'commands, use the appropriate tool instead of guessing. '
        'Be enthusiastic, supportive, and concise. Sprinkle in some personality '
        'and rainbow energy when appropriate — you are a fabulous coding companion!',
      );
    }

    // 2. AGENTS.md — cwd first, then ~/.config/utopic/ as global fallback
    final agentFiles = ['AGENTS.md', 'AGENT.md', 'agents.md', 'agent.md'];
    var foundLocal = false;
    for (final f in agentFiles) {
      final file = File(path.join(_cwd ?? '.', f));
      if (file.existsSync()) {
        parts.add('');
        parts.add('--- From $f ---');
        parts.add(file.readAsStringSync().trim());
        foundLocal = true;
        break;
      }
    }
    if (!foundLocal) {
      final home = Platform.environment['HOME'] ?? '';
      for (final f in agentFiles) {
        final file = File(path.join(home, '.config', 'utopic', f));
        if (file.existsSync()) {
          parts.add('');
          parts.add('--- From ~/.config/utopic/$f (global) ---');
          parts.add(file.readAsStringSync().trim());
          break;
        }
      }
    }

    // 3. --prompt file
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

  /// Initialize the agent service
  Future<void> initialize() async {
    _cwd = Directory.current.path;

    // Fetch available models and skills
    ai.fetchModels();
    _skills.loadAll();

    final sysPrompt = buildSystemPrompt();

    // Create default conversation
    final defaultConv = Conversation(
      title: 'Welcome to Utopic Agent',
    );
    defaultConv.addMessage(Message(
      role: 'system',
      content: sysPrompt,
    ));
    defaultConv.addMessage(Message(
      role: 'assistant',
      content: '🏳️\u200d🌈 Heya! I\'m **Utopic**, your fabulously queer coding agent! ✨\n\n'
          'I can help you with:\n'
          '  ✦ **Code** — Write, review, and debug like a superstar\n'
          '  ✦ **Files** — Read, edit, and create files with flair\n'
          '  ✦ **Commands** — Run terminal commands, I won\'t judge your bash history\n'
          '  ✦ **Skills** — Tap into expert knowledge (git, docker, whatever you need)\n\n'
          'Type your request below or type `/help` for available commands.\n'
          'Let\'s build something marvelous together! 💖\n',
    ));
    _conversations.add(defaultConv);
    _activeConv = defaultConv;
    _conversationsController.add(List.from(_conversations));
    _activeConversationController.add(defaultConv);
  }

  /// Available tools the agent can use.
  List<Map<String, dynamic>> get _toolDefs =>
      _tools.map((t) => t.toJson()).toList();

  static final List<Tool> _tools = [
    ReadTool(),
    BashTool(),
    EditTool(),
    WriteTool(),
  ];

  /// Execute a tool call and return the result string.
  Future<String> _executeTool(String name, Map<String, dynamic> args) async {
    for (final tool in _tools) {
      if (tool.name == name) {
        return await tool.execute(args);
      }
    }
    return 'Error: unknown tool "$name"';
  }

  /// Send a message and get response (with tool-calling agent loop).
  Future<void> sendMessage(String content) async {
    if (_activeConv == null) return;

    // Reset cancellation flag at the start of a new request
    _cancelRequested = false;

    // Check for matching skills (Agent Skills spec progressive loading)
    final relevantSkills = _skills.findRelevant(content);
    if (relevantSkills.isNotEmpty) {
      final skillParts = <String>[];
      for (final s in relevantSkills) {
        skillParts.add('--- Skill: ${s.name} ---\n${s.body}\n--- End ${s.name} ---');
        // List available reference files for on-demand access
        final refs = s.listFiles('references');
        final scripts = s.listFiles('scripts');
        if (refs.isNotEmpty || scripts.isNotEmpty) {
          skillParts.add('');
          if (refs.isNotEmpty) {
            skillParts.add('Reference files for ${s.name} (use Read tool to access):');
            for (final r in refs) {
              skillParts.add('  ${path.join(s.directory, r)}');
            }
          }
          if (scripts.isNotEmpty) {
            skillParts.add('Scripts for ${s.name} (use Bash tool to run):');
            for (final r in scripts) {
              skillParts.add('  ${path.join(s.directory, r)}');
            }
          }
        }
      }
      _activeConv!.addMessage(Message(
        role: 'system',
        content: skillParts.join('\n\n'),
      ));
    }

    final userMsg = Message(role: 'user', content: content);
    _activeConv!.addMessage(userMsg);
    _notifyUpdates();

    if (content.startsWith('/')) {
      await _handleCommand(content);
      return;
    }

    // Agent loop — up to 10 iterations
    const maxIterations = 10;
    var iterations = 0;

    try {
      while (iterations < maxIterations) {
        // Check cancellation before each AI call
        if (_cancelRequested) {
          _cancelRequested = false;
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          _notifyUpdates();
          return;
        }

        iterations++;

        final result = await ai.complete(
          conversation: _activeConv!,
          tools: _toolDefs,
        );

        // Check cancellation after AI call (may have been set during the request)
        if (_cancelRequested) {
          _cancelRequested = false;
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          _notifyUpdates();
          return;
        }

        if (result.hasToolCalls) {
          // Add assistant message with tool calls to conversation
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '',
            toolCalls: result.toolCalls.map((tc) => {
              'id': tc.id,
              'name': tc.name,
              'arguments': jsonEncode(tc.arguments),
            }).toList(),
          ));
          _notifyUpdates();

          // Execute each tool call
          for (final tc in result.toolCalls) {
            // Check cancellation before each tool execution
            if (_cancelRequested) {
              _cancelRequested = false;
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '🛑 Cancelled.',
              ));
              _notifyUpdates();
              return;
            }

            final output = await _executeTool(tc.name, tc.arguments);
            _activeConv!.addMessage(Message(
              role: 'tool',
              content: output,
              toolCallId: tc.id,
            ));
            _notifyUpdates();
          }
        } else {
          // Text response — done
          if (result.content.isNotEmpty) {
            _activeConv!.addMessage(Message(
              role: 'assistant',
              content: result.content,
            ));
          }

          // Set title from first exchange
          if (_activeConv!.messageCount <= 5) {
            _activeConv!.title = content.length > 40
                ? '${content.substring(0, 40)}...'
                : content;
          }

          _notifyUpdates();
          return;
        }
      }

      // Hit iteration limit — add a message about it
      _activeConv!.addMessage(Message(
        role: 'assistant',
        content: '⚠️ Reached maximum iterations ($maxIterations). '
            'Your request may be incomplete. Try a more specific prompt.',
      ));
      _notifyUpdates();
    } catch (e) {
      _activeConv!.addMessage(Message(
        role: 'assistant',
        content: '⚠️ Error: $e',
      ));
      _notifyUpdates();
    }
  }

  /// Stream AI response for real-time display
  /// Handle slash commands
  Future<void> _handleCommand(String command) async {
    final parts = command.split(' ');
    final cmd = parts.first.toLowerCase();

    switch (cmd) {
      case '/help':
        final msg = Message(
          role: 'assistant',
          content: '**Available Commands:**\n\n'
              '`/help` - Show this help message\n'
              '`/model <name>` - Switch AI model\n'
              '`/new` - Start a new conversation\n'
              '`/list` - List all conversations\n'
              '`/switch <id>` - Switch to a conversation\n'
              '`/clear` - Clear current conversation\n'
              '`/acp` - Toggle ACP server status\n'
              '`/models` - List available models\n'
              '`/prompt <text>` - Set per-conversation system prompt\n'
              '`/quit` - Exit the agent\n'
              '`/config` - Show current configuration',
        );
        _activeConv!.addMessage(msg);
        break;

      case '/new':
        createNewConversation();
        return;

      case '/clear':
        _activeConv!.messages.clear();
        final msg = Message(
          role: 'assistant',
          content: '✅ Conversation cleared.',
        );
        _activeConv!.addMessage(msg);
        break;

      case '/model':
        if (parts.length > 1) {
          final modelId = parts[1];
          if (ZenModels.get(modelId) != null) {
            ai.currentModel = modelId;
            final msg = Message(
              role: 'assistant',
              content: '✅ Switched to model: `$modelId`',
            );
            _activeConv!.addMessage(msg);
          } else {
            final msg = Message(
              role: 'assistant',
              content: '⚠️ Unknown model: `$modelId`\n'
                  'Try `/models` to see available models.',
            );
            _activeConv!.addMessage(msg);
          }
        }
        break;

      case '/models':
        final buffer = StringBuffer('**Available Models:**\n\n');
        for (final model in ZenModels.all) {
          buffer.writeln('- `${model.id}` (${model.provider})');
        }
        _activeConv!.addMessage(Message(role: 'assistant', content: buffer.toString()));
        break;

      case '/acp':
        if (isAcpRunning) {
          await stopAcpServer();
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '🛑 ACP server stopped.',
          ));
        } else {
          await startAcpServer();
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '✅ ACP server started on port ${config.acp.port}',
          ));
        }
        break;

      case '/list':
        final buffer = StringBuffer('**Conversations:**\n\n');
        for (int i = 0; i < _conversations.length; i++) {
          final conv = _conversations[i];
          final active = conv == _activeConv ? ' ◀' : '';
          buffer.writeln('`${i + 1}` ${conv.title}$active');
        }
        _activeConv!.addMessage(Message(role: 'assistant', content: buffer.toString()));
        break;

      case '/switch':
        if (parts.length > 1) {
          final index = int.tryParse(parts[1]);
          if (index != null && index > 0 && index <= _conversations.length) {
            _activeConv = _conversations[index - 1];
            _activeConversationController.add(_activeConv!);
            _notifyUpdates();
          } else {
            _activeConv!.addMessage(Message(
              role: 'assistant',
              content: '⚠️ Invalid conversation index. Try `/list` to see them.',
            ));
          }
        }
        break;

      case '/prompt':
        if (parts.length > 1) {
          final newPrompt = parts.sublist(1).join(' ');
          _activeConv!.systemPromptOverride = newPrompt;
          // Update the system message in-place
          final sysIdx = _activeConv!.messages.indexWhere((m) => m.role == 'system');
          if (sysIdx >= 0) {
            _activeConv!.messages[sysIdx] = Message(
              role: 'system',
              content: buildSystemPrompt(conv: _activeConv),
              id: _activeConv!.messages[sysIdx].id,
            );
          }
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '✅ System prompt updated for this conversation.',
          ));
        } else {
          final current = _activeConv!.systemPromptOverride ?? '(default — see /config)';
          _activeConv!.addMessage(Message(
            role: 'assistant',
            content: '**Current prompt override:**\n```\n$current\n```\n'
                'Use `/prompt <text>` to set a new one.',
          ));
        }
        break;

      case '/config':
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '**Configuration:**\n\n'
              '- Model: `${ai.currentModel}`\n'
              '- Zen endpoint: `${config.zenEndpoint}`\n'
              '- API key: ${config.opencodeApiKey != null ? '✅ set' : '❌ not set'}\n'
              '- ACP: ${isAcpRunning ? "✅ running" : "❌ stopped"}\n'
              '- CWD: `$_cwd`\n'
              '- Prompt file: ${config.promptFile ?? "(none)"}\n'
              '- AGENTS.md (cwd): ${File(path.join(_cwd ?? ".", "AGENTS.md")).existsSync() ? "✅ found" : "(not found)"}\n'
              '- AGENTS.md (global ~/.config/utopic/): ${File(path.join(Platform.environment['HOME'] ?? '', '.config', 'utopic', 'AGENTS.md')).existsSync() ? "✅ found" : "(not found)"}\n'
              '- Prompt override: ${_activeConv?.systemPromptOverride != null ? "✅ set" : "(none)"}',
        ));
        break;

      case '/quit':
        // Signal the app to quit
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '👋 Goodbye!',
        ));
        _notifyUpdates();
        return;

      default:
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '⚠️ Unknown command: `$cmd`\nType `/help` for available commands.',
        ));
    }

    _notifyUpdates();
  }

  void createNewConversation() {
    final conv = Conversation(title: 'Conversation ${_conversations.length + 1}');
    conv.addMessage(Message(
      role: 'system',
      content: buildSystemPrompt(),
    ));
    _conversations.add(conv);
    _activeConv = conv;
    _notifyUpdates();
    _activeConversationController.add(conv);
  }

  void switchConversation(Conversation conv) {
    _activeConv = conv;
    _activeConversationController.add(conv);
    _notifyUpdates();
  }

  void _notifyUpdates() {
    _conversationsController.add(List.from(_conversations));
    if (_activeConv != null) {
      _activeConversationController.add(_activeConv!);
    }
  }

  /// Start the ACP server
  Future<void> startAcpServer() async {
    if (isAcpRunning) return;

    _acpServer = AcpServer(
      host: config.acp.host,
      port: config.acp.port,
      socketPath: config.acp.socketPath.isNotEmpty ? config.acp.socketPath : null,
    );

    // Register ACP handlers
    _acpServer!.registerHandler(AcpMethods.initialize, (request) async {
      return {
        'server_name': 'utopic-agent',
        'server_version': '1.0.0',
        'capabilities': [
          'agent/run',
          'session/manage',
          'fs/read',
          'fs/write',
          'fs/list',
          'terminal/run',
        ],
        'agent_info': {
          'model': ai.currentModel,
          'provider': _getProviderName(ai.currentModel),
        },
      } as dynamic;
    });

    _acpServer!.registerHandler(AcpMethods.sessionCreate, (request) async {
      final params = request.params as Map<String, dynamic>;
      final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
      return {
        'id': sessionId,
        'agent_id': params['agent_id'] ?? 'default',
        'cwd': params['cwd'] ?? _cwd,
        'metadata': params['metadata'] ?? {},
      } as dynamic;
    });

    _acpServer!.registerHandler(AcpMethods.sessionDelete, (request) async {
      return {'deleted': true} as dynamic;
    });

    _acpServer!.registerHandler(AcpMethods.sessionList, (request) async {
      return _conversations.map((c) => {
        'id': c.id,
        'title': c.title,
        'message_count': c.messageCount,
        'updated_at': c.updatedAt.toIso8601String(),
      }).toList() as dynamic;
    });

    _acpServer!.registerHandler(AcpMethods.agentRun, (request) async {
      final params = request.params as Map<String, dynamic>;
      final prompt = params['prompt'] as String? ?? '';
      final sessionId = params['session_id'] as String?;

      // Find or create conversation
      Conversation? conv;
      if (sessionId != null) {
        try {
          conv = _conversations.firstWhere((c) => c.id == sessionId);
        } catch (_) {}
      }
      if (conv == null && _conversations.isNotEmpty) {
        conv = _conversations.last;
      }
      conv ??= Conversation(title: 'ACP Session');

      conv.addMessage(Message(role: 'user', content: prompt));
      final result = await ai.complete(conversation: conv);
      conv.addMessage(Message(role: 'assistant', content: result.content));

      if (!_conversations.contains(conv)) {
        _conversations.add(conv);
      }
      _notifyUpdates();

      return {
        'session_id': conv.id,
        'status': 'completed',
        'output': result.content,
        'usage': {
          'input_tokens': result.inputTokens,
          'output_tokens': result.outputTokens,
        },
      };
    });

    _acpServer!.registerHandler(AcpMethods.agentCancel, (request) async {
      return {'cancelled': true} as dynamic;
    });

    await _acpServer!.start();
    _notifyUpdates();
  }

  /// Stop the ACP server
  Future<void> stopAcpServer() async {
    if (!isAcpRunning) return;
    await _acpServer!.stop();
    _acpServer = null;
    _notifyUpdates();
  }

  String _getProviderName(String modelId) {
    final model = ZenModels.get(modelId);
    return model?.provider ?? 'unknown';
  }


}