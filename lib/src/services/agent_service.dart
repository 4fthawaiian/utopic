import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;

import '../config/app_config.dart';
import '../models/conversation.dart';
import '../models/zen_models.dart';
import '../acp/acp.dart';
import 'ai_service.dart';
import 'session_store.dart';
import 'skills.dart';
import 'tools/tools.dart';

/// Manages the agent lifecycle including ACP server and conversations
class AgentService implements AcpAgentDelegate {
  final AppConfig config;
  AiService ai;
  final List<Conversation> _conversations = [];
  AcpServer? _acpServer;
  AcpDartConnection? _acpConnection;
  ZenAiService? _zenFallback;
  final SessionStore _sessionStore = SessionStore();
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

  /// The port the ACP server is bound to (null if not running).
  int? get acpPort => _acpServer?.boundPort;

  final SkillLoader _skills = SkillLoader();

  AgentService({required this.config, AiService? aiService})
      : ai = aiService ?? ZenAiService(config: config);

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

  /// Whether phobe mode is enabled (remove pride theming).
  /// Set before [initialize] to control the welcome message.
  bool phobeMode = false;

  /// Initialize the agent service
  Future<void> initialize() async {
    _cwd = Directory.current.path;

    // Fetch available models and skills
    ai.fetchModels();
    _skills.loadAll();

    final sysPrompt = buildSystemPrompt();

    // Load saved sessions from disk (for /list and /switch access)
    final savedSessions = _sessionStore.list();
    for (final s in savedSessions) {
      final conv = _sessionStore.load(s['id'] as String);
      if (conv != null) {
        _conversations.add(conv);
      }
    }

    // Always start with a fresh conversation so the user sees a clean slate.
    // Saved sessions are still available via /list and /switch.
    final freshConv = Conversation(
      title: 'Welcome to Utopic Agent',
    );
    freshConv.addMessage(Message(
      role: 'system',
      content: sysPrompt,
    ));
    if (phobeMode) {
      freshConv.addMessage(Message(
        role: 'assistant',
        content: '**Utopic** here. Let\'s write some code.\n\n'
            'I can help you with:\n'
            '  - **Code** — Write, review, and debug\n'
            '  - **Files** — Read, edit, and create files\n'
            '  - **Commands** — Run terminal commands\n'
            '  - **Skills** — Tap into expert knowledge\n\n'
            'Type your request or `/help` for commands.\n',
      ));
    } else {
      freshConv.addMessage(Message(
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
    }
    _conversations.add(freshConv);

    _activeConv = freshConv;
    _conversationsController.add(List.from(_conversations));
    _activeConversationController.add(freshConv);
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

  /// Run the agent tool-calling loop on a conversation that already has a user
  /// message appended.  Handles up to [maxIterations] rounds of:
  ///   AI call → tool calls? → execute tools → loop → text response
  ///
  /// If [acpStream] is provided (an ACP [AgentSideConnection] + [sessionId]),
  /// intermediate progress is streamed as session/update notifications so the
  /// remote client (e.g. Paseo) can show thinking and tool-call progress.
  ///
  /// Returns the final [AiResult] on success, or `null` if cancelled or if the
  /// iteration limit was reached without a text response.
  Future<AiResult?> _runAgentLoop(
    Conversation conv, {
    AgentSideConnection? acpConnection,
    String? acpSessionId,
  }) async {
    final maxIterations = config.maxIterations;
    var iterations = 0;

    /// Send an ACP session update if we're streaming to a remote client.
    Future<void> sendAcpUpdate(SessionUpdate update) async {
      if (acpConnection == null || acpSessionId == null) return;
      try {
        await acpConnection.sessionUpdate(SessionNotification(
          sessionId: acpSessionId,
          update: update,
        ));
      } catch (e) {
        stderr.writeln('ACP stream error: $e');
      }
    }

    try {
      while (iterations < maxIterations) {
        // Check cancellation before each AI call
        if (_cancelRequested) {
          _cancelRequested = false;
          conv.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          _notifyUpdates();
          return null;
        }

        iterations++;

        // Send a "thinking" update to the ACP client so they know
        // the AI is processing (instead of silence).
        await sendAcpUpdate(AgentThoughtChunkSessionUpdate(
          content: TextContentBlock(
            text: iterations > 1
                ? 'Continuing agent loop (round $iterations)...'
                : 'Thinking...',
          ),
        ));

        final result = await ai.complete(
          conversation: conv,
          tools: _toolDefs,
        );

        // Check cancellation after AI call (may have been set during the request)
        if (_cancelRequested) {
          _cancelRequested = false;
          conv.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          _notifyUpdates();
          return null;
        }

        if (result.hasToolCalls) {
          // Add assistant message with tool calls to conversation
          // Preserve any text the AI returned alongside the tool calls
          // (reasoning, commentary before calling tools).
          conv.addMessage(Message(
            role: 'assistant',
            content: result.content,
            toolCalls: result.toolCalls.map((tc) => {
              'id': tc.id,
              'name': tc.name,
              'arguments': jsonEncode(tc.arguments),
            }).toList(),
          ));
          _notifyUpdates();

          // Stream any text that came with the tool calls
          if (result.content.isNotEmpty) {
            await sendAcpUpdate(AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: result.content),
            ));
          }

          // Stream tool call notifications so the client can see them
          for (final tc in result.toolCalls) {
            await sendAcpUpdate(ToolCallSessionUpdate(
              toolCallId: tc.id,
              title: tc.name,
              status: ToolCallStatus.inProgress,
              rawInput: tc.arguments,
              kind: _toolKindFor(tc.name),
              locations: _toolLocationsFor(tc.name, tc.arguments),
            ));
          }

          // Execute each tool call
          for (final tc in result.toolCalls) {
            // Check cancellation before each tool execution
            if (_cancelRequested) {
              _cancelRequested = false;
              conv.addMessage(Message(
                role: 'assistant',
                content: '🛑 Cancelled.',
              ));
              _notifyUpdates();
              return null;
            }

            final output = await _executeTool(tc.name, tc.arguments);
            conv.addMessage(Message(
              role: 'tool',
              content: output,
              toolCallId: tc.id,
            ));
            _notifyUpdates();

            // Send tool result as an update
            await sendAcpUpdate(ToolCallUpdateSessionUpdate(
              toolCallId: tc.id,
              title: tc.name,
              status: ToolCallStatus.completed,
              rawOutput: {'result': output.length > 500 ? '${output.substring(0, 500)}...' : output},
            ));
          }
        } else {
          // Text response — done
          if (result.content.isNotEmpty) {
            conv.addMessage(Message(
              role: 'assistant',
              content: result.content,
            ));
          }
          _notifyUpdates();

          // Stream the final text response
          if (result.content.isNotEmpty) {
            await sendAcpUpdate(AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: result.content),
            ));
          }
          return result;
        }
      }

      // Hit iteration limit
      conv.addMessage(Message(
        role: 'assistant',
        content: '⚠️ Reached maximum iterations ($maxIterations). '
            'Your request may be incomplete. Try a more specific prompt.',
      ));
      _notifyUpdates();
      await sendAcpUpdate(AgentMessageChunkSessionUpdate(
        content: TextContentBlock(
          text: '⚠️ Reached maximum iterations ($maxIterations). '
              'Your request may be incomplete. Try a more specific prompt.',
        ),
      ));
      return null;
    } catch (e) {
      conv.addMessage(Message(
        role: 'assistant',
        content: '⚠️ Error: $e',
      ));
      _notifyUpdates();
      await sendAcpUpdate(AgentMessageChunkSessionUpdate(
        content: TextContentBlock(text: '⚠️ Error: $e'),
      ));
      rethrow;
    }
  }

  /// Map a tool name to the appropriate [ToolKind] for ACP tool call updates.
  ToolKind _toolKindFor(String name) {
    switch (name) {
      case 'read':
        return ToolKind.read;
      case 'write':
        return ToolKind.edit;
      case 'edit':
        return ToolKind.edit;
      case 'bash':
        return ToolKind.execute;
      default:
        return ToolKind.other;
    }
  }

  /// Extract file locations from tool arguments for ACP tool call updates.
  List<ToolCallLocation> _toolLocationsFor(String name, Map<String, dynamic> args) {
    final path = args['path'] as String? ?? args['file'] as String?;
    if (path != null) {
      return [ToolCallLocation(path: path)];
    }
    return [];
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

    final result = await _runAgentLoop(_activeConv!);

    // Set title from first exchange
    if (result != null && _activeConv!.messageCount <= 5) {
      _activeConv!.title = content.length > 40
          ? '${content.substring(0, 40)}...'
          : content;
    }

    // Auto-save after each exchange
    await saveCurrentSession();
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
              '`/phobe` - Toggle phobe mode (remove pride theming)'
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
              '- ACP: ${isUsingAcp ? "✅ provider (${ai.currentModel})" : (isAcpRunning ? "✅ server running" : "❌ stopped")}\n'
              '- CWD: `$_cwd`\n'
              '- Prompt file: ${config.promptFile ?? "(none)"}\n'
              '- AGENTS.md (cwd): ${File(path.join(_cwd ?? ".", "AGENTS.md")).existsSync() ? "✅ found" : "(not found)"}\n'
              '- AGENTS.md (global ~/.config/utopic/): ${File(path.join(Platform.environment['HOME'] ?? '', '.config', 'utopic', 'AGENTS.md')).existsSync() ? "✅ found" : "(not found)"}\n'
              '- Prompt override: ${_activeConv?.systemPromptOverride != null ? "✅ set" : "(none)"}',
        ));
        break;

      case '/phobe':
        // Phobe mode is handled by the TUI, but if the message reaches
        // the agent (e.g. programmatic input), acknowledge it.
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '⚠️ Phobe mode can only be toggled from inside the TUI '
              'with the `/phobe` command or at startup with `--phobe`.'
              'The TUI is not available in this mode.',
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
  Future<void> startAcpServer({bool stdio = false}) async {
    if (isAcpRunning) return;

    _acpServer = AcpServer(
      host: config.acp.host,
      port: config.acp.port,
      socketPath: config.acp.socketPath.isNotEmpty ? config.acp.socketPath : null,
      delegate: this,
    );

    if (stdio) {
      await _acpServer!.startStdio();
    } else {
      await _acpServer!.start();
    }
    _notifyUpdates();
  }

  /// Whether the agent is currently using a remote ACP server as its
  /// model provider.
  bool get isUsingAcp => ai is AcpAiService;
  /// Connect to a remote ACP server and use it as the model provider.
  ///
  /// Saves the current [ZenAiService] as a fallback so [disconnectFromAcp]
  /// can restore it.
  Future<Map<String, dynamic>> connectToAcp(String host, int port) async {
    if (_acpConnection != null) await _acpConnection!.disconnect();

    final conn = AcpDartConnection();
    try {
      await conn.connectToTcp(host, port);
      await conn.createSession();
      _acpConnection = conn;
      _swapToAcp(conn);
      return {
        'server_name': conn.serverName,
        'agent_info': {'model': conn.currentModelId ?? 'unknown'},
      };
    } catch (e) {
      await conn.disconnect();
      rethrow;
    }
  }

  /// Connect to a local CLI subprocess and use it as the model provider.
  ///
  /// [command] is the executable path; [args] are optional arguments.
  /// Communicates via stdin/stdout using the same JSON-RPC 2.0 protocol.
  Future<Map<String, dynamic>> connectToAcpCli(String command, {List<String> args = const []}) async {
    if (_acpConnection != null) await _acpConnection!.disconnect();
    _acpConnection = null;

    final conn = AcpDartConnection();
    try {
      await conn.connectToCli(command, args);
      // Create session eagerly so server sends model config options
      await conn.createSession();
      _acpConnection = conn;
      _swapToAcp(conn);
      return {
        'server_name': conn.serverName,
        'agent_info': {'model': conn.currentModelId ?? 'unknown'},
      };
    } catch (e) {
      await conn.disconnect();
      rethrow;
    }
  }

  void _swapToAcp(AcpDartConnection conn) {
    if (ai is ZenAiService) {
      _zenFallback = ai as ZenAiService;
    }
    ai = AcpAiService(config: config, conn: conn);
    _notifyUpdates();
  }

  /// Disconnect from the remote ACP server and restore the Zen API provider.
  Future<void> disconnectFromAcp() async {
    if (_acpConnection != null) {
      await _acpConnection!.disconnect();
      _acpConnection = null;
    }
    ai = _zenFallback ?? ZenAiService(config: config);
    _zenFallback = null;
    _notifyUpdates();
  }

  /// A future that completes when the ACP server stops (e.g. stdin EOF
  /// in stdio mode).
  Future<void> get acpServerDone => _acpServer?.done ?? Future.value();

  /// Stop the ACP server
  Future<void> stopAcpServer() async {
    if (!isAcpRunning) return;
    await _acpServer!.stop();
    _acpServer = null;
    _notifyUpdates();
  }

  // ─── Session persistence ────────────────────────────────────────────

  /// Save the active conversation to disk.
  Future<void> saveCurrentSession() async {
    if (_activeConv == null) return;
    if (_activeConv!.messageCount <= 1) return; // don't save empty convos
    try {
      _sessionStore.save(_activeConv!);
    } catch (_) {
      // Silently fail — persistence is best-effort
    }
  }

  /// Load a saved conversation by ID and switch to it.
  Future<Conversation?> loadSession(String id) async {
    final conv = _sessionStore.load(id);
    if (conv == null) return null;

    // Replace or add
    final idx = _conversations.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      _conversations[idx] = conv;
    } else {
      _conversations.add(conv);
    }
    _activeConv = conv;
    _notifyUpdates();
    _activeConversationController.add(conv);
    return conv;
  }

  /// List all saved sessions (metadata only).
  List<Map<String, dynamic>> listSavedSessions() => _sessionStore.list();

  // ─── AcpAgentDelegate implementation ─────────────────────────────────

  @override
  Map<String, dynamic> onInitialize() {
    return {
      'server_name': 'utopic-agent',
      'server_version': '1.0.0',
      'model': ai.currentModel,
    };
  }

  @override
  Map<String, dynamic> onNewSession(String cwd) {
    final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    return {
      'id': sessionId,
      'cwd': cwd,
      'model': ai.currentModel,
      'models': ZenModels.all.map((m) => {
        'id': m.id,
        'name': m.displayName,
        'description': '${m.provider} · ${m.contextLimit ~/ 1000}K context',
      }).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> onPrompt({
    required String sessionId,
    required String prompt,
    required AgentSideConnection connection,
  }) async {
    // Find or create conversation
    Conversation? conv;
    try {
      conv = _conversations.firstWhere((c) => c.id == sessionId);
    } catch (_) {}
    if (conv == null) {
      if (_conversations.isNotEmpty) {
        conv = _conversations.last;
      } else {
        conv = Conversation(title: 'ACP Session');
      }
    }

    // Ensure system prompt for new conversations
    if (conv.messageCount == 0) {
      conv.addMessage(Message(
        role: 'system',
        content: buildSystemPrompt(),
      ));
    }

    conv.addMessage(Message(role: 'user', content: prompt));
    _notifyUpdates();

    // Run the agent loop with ACP streaming enabled — it sends intermediate
    // thought, tool-call, and text updates so the client (Paseo) can display
    // real-time progress instead of just the final result.
    final result = await _runAgentLoop(
      conv,
      acpConnection: connection,
      acpSessionId: sessionId,
    );

    if (!_conversations.contains(conv)) {
      _conversations.add(conv);
    }

    if (result != null) {
      if (result.content.isEmpty && result.toolCalls.isEmpty) {
        stderr.writeln('ACP: AI returned empty content after prompt (tokens: '
            'input=${result.inputTokens}, output=${result.outputTokens})');
      }
      return {
        'inputTokens': result.inputTokens,
        'outputTokens': result.outputTokens,
      };
    } else {
      return {
        'inputTokens': 0,
        'outputTokens': 0,
      };
    }
  }

  @override
  void onCancel(String sessionId) {
    _cancelRequested = true;
  }

  @override
  List<Map<String, dynamic>> onListSessions() {
    return _conversations.map((c) => {
      'id': c.id,
      'title': c.title,
      'cwd': _cwd,
      'updated_at': c.updatedAt.toIso8601String(),
    }).toList();
  }
}