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
  OpenRouterAiService? _openrouterFallback;
  LmStudioAiService? _lmStudioFallback;
  final SessionStore _sessionStore = SessionStore();
  String? _cwd;
  bool _cancelRequested = false;

  /// Request cancellation of the current agent run.
  /// The agent loop will stop at the next safe point and abort any
  /// in-flight AI HTTP request.
  void cancel() {
    _cancelRequested = true;
    ai.cancel();
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

  /// Track active ACP sessions so we can push model list updates to Paseo.
  final Map<String, AgentSideConnection> _acpSessions = {};

  /// Maps ACP session IDs (e.g. `session_123`) to internal conversation IDs
  /// (e.g. `conv_456_789`). Used for session/load and session/resume.
  final Map<String, String> _acpSessionToConvId = {};

  AgentService({required this.config, AiService? aiService})
      : ai = aiService ?? _createDefaultAi(config);

  /// Human-readable display name for a provider.
  static String _providerDisplayName(AiProvider p) {
    switch (p) {
      case AiProvider.openrouter:
        return 'OpenRouter';
      case AiProvider.lmstudio:
        return 'LM Studio';
      case AiProvider.zen:
        return 'Zen';
    }
  }

  /// Create the default AI service based on the config provider setting.
  static AiService _createDefaultAi(AppConfig cfg) {
    switch (cfg.provider) {
      case AiProvider.openrouter:
        return OpenRouterAiService(config: cfg);
      case AiProvider.lmstudio:
        return LmStudioAiService(config: cfg);
      case AiProvider.zen:
        return ZenAiService(config: cfg);
    }
  }

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

    // Fetch available models from both providers so Paseo and the TUI
    // always see a complete list of models regardless of which provider
    // is currently active.
    // Always try Zen models
    try {
      if (ai is ZenAiService) {
        await (ai as ZenAiService).fetchModels();
      } else {
        // Use a temporary ZenAiService to fetch models without switching
        final zen = ZenAiService(config: config);
        await zen.fetchModels();
      }
    } catch (e) {
      stderr.writeln('[utopic] Zen model fetch failed: $e');
    }

    // Always try OpenRouter models too (silently if no key configured)
    try {
      if (config.openrouterApiKey != null && config.openrouterApiKey!.isNotEmpty) {
        final or = OpenRouterAiService(config: config);
        await or.fetchModels();
      }
    } catch (e) {
      stderr.writeln('[utopic] OpenRouter model fetch failed: $e');
    }

    // Always try LM Studio models (with timeout — remote endpoints can be slow)
    try {
      final lm = LmStudioAiService(config: config);
      await lm.fetchModels().timeout(const Duration(seconds: 10));
      final lmCount = ZenModels.lmStudioAll.length;
      stderr.writeln('[utopic] LM Studio: $lmCount model(s) loaded from ${config.lmStudioEndpoint}');
    } catch (e) {
      stderr.writeln('[utopic] LM Studio model fetch failed (endpoint: ${config.lmStudioEndpoint}): $e');
      stderr.writeln('[utopic]   Only "local-model" will be shown. Check your lm_studio_endpoint in config.yaml');
      stderr.writeln('[utopic]   Expected format: http://host:port/v1  (note: /v1 suffix is required)');
    }
    _skills.loadAll();

    final sysPrompt = buildSystemPrompt();

    // Load saved sessions from disk (for /list and /switch access)
    final savedSessions = _sessionStore.list();
    for (final s in savedSessions) {
      final conv = _sessionStore.load(s['id'] as String);
      if (conv != null) {
        _conversations.add(conv);
        // Repopulate the ACP session → conversation ID mapping so that
        // session/resume and session/load work across restarts.
        // ACP sessions use their session ID (e.g. "session_123...") as the
        // conversation ID, so the mapping is identity-based.
        _acpSessionToConvId[conv.id] = conv.id;
      }
    }

    // Always start with a fresh conversation so the user sees a clean slate.
    // Saved sessions are still available via /list and /switch.
    final freshConv = Conversation(
      title: 'Welcome to Utopic Agent',
      contextLimit: ZenModels.contextLimitFor(ai.currentModel),
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
    final stopwatch = Stopwatch()..start();

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

    /// Send a thought update with a descriptive message about what the
    /// agent is currently doing.
    Future<void> sendThought(String message) async {
      await sendAcpUpdate(AgentThoughtChunkSessionUpdate(
        content: TextContentBlock(text: message),
      ));
    }

    /// Ensure the conversation's context limit matches the current model.
    void syncContextLimit() {
      conv.contextLimit = ZenModels.contextLimitFor(ai.currentModel);
    }

    /// Send a usage update with actual context window info.
    ///
    /// This tells the client (e.g. Paseo) how much of the context window
    /// has been consumed so it can display a percentage bar and token counts.
    Future<void> sendUsage() async {
      syncContextLimit();
      final used = conv.contextTokens;
      final limit = conv.contextLimit;
      await sendAcpUpdate(UsageUpdate(
        size: limit,
        used: used,
        cost: Cost(
          amount: used * 0.000001,
          currency: 'USD',
        ),
      ));
    }

    try {
      // Ensure context limit is synced and send an initial UsageUpdate
      // so Paseo immediately shows a context bar, even before the first AI call.
      syncContextLimit();
      if (conv.contextTokens == 0) {
        // Estimate tokens from the conversation so far (system prompt, etc.)
        conv.contextTokens = conv.estimateContextTokens();
      }
      await sendUsage();

      while (iterations < maxIterations) {
        // Check cancellation before each AI call
        if (_cancelRequested) {
          _cancelRequested = false;
          conv.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          await sendAcpUpdate(AgentMessageChunkSessionUpdate(
            content: TextContentBlock(text: '🛑 Cancelled.'),
          ));
          _notifyUpdates();
          return null;
        }

        iterations++;

        // Build a descriptive thinking message based on the current round
        // and what we know about the state.
        final modelName = ai.currentModel;
        if (iterations == 1) {
          await sendThought(
            '🤔 **Analyzing your request** (using `$modelName`)…',
          );
        } else {
          // Try to summarize what the last tool results were about so the
          // thinking message is actually informative.
          final lastMsg = conv.messages.isNotEmpty
              ? conv.messages.last
              : null;
          final lastToolResult = lastMsg != null && lastMsg.role == 'tool'
              ? _summarizeToolResult(lastMsg.content)
              : null;

          if (lastToolResult != null) {
            await sendThought(
              '🤔 **Processing results** (round $iterations/$maxIterations · '
              '`$modelName`)\n'
              '└ _Last tool result: ${lastToolResult}_',
            );
          } else {
            await sendThought(
              '🤔 **Continuing analysis** (round $iterations/$maxIterations · '
              '`$modelName`)…',
            );
          }
        }

        // Wrap the AI call so that if cancellation closes the HTTP
        // client (via ai.cancel()), we catch the resulting error and
        // treat it as a clean cancellation rather than an ugly error.
        AiResult result;
        try {
          result = await ai.complete(
            conversation: conv,
            tools: _toolDefs,
          );
        } catch (_) {
          // If cancellation was requested during the HTTP request,
          // the closed client will throw — handle cleanly.
          if (_cancelRequested) {
            _cancelRequested = false;
            conv.addMessage(Message(
              role: 'assistant',
              content: '🛑 Cancelled.',
            ));
            await sendAcpUpdate(AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: '🛑 Cancelled.'),
            ));
            _notifyUpdates();
            return null;
          }
          rethrow;
        }

        // Store the actual context size from the API response.
        // result.inputTokens reflects the full conversation sent to the model,
        // so this is the real, authoritative token count.
        conv.contextTokens = result.inputTokens;
        // Re-sync context limit in case the model changed inside
        // ai.complete() (e.g. via ACP model switch).
        syncContextLimit();

        // Check cancellation after AI call (may have been set during the request)
        if (_cancelRequested) {
          _cancelRequested = false;
          conv.addMessage(Message(
            role: 'assistant',
            content: '🛑 Cancelled.',
          ));
          await sendAcpUpdate(AgentMessageChunkSessionUpdate(
            content: TextContentBlock(text: '🛑 Cancelled.'),
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

          // Stream the AI's reasoning / commentary as a message chunk
          // BEFORE the tool call notifications, so the client sees the
          // "why" behind the tool calls as actual message text (not hidden
          // in the thinking block).
          if (result.content.isNotEmpty) {
            await sendAcpUpdate(AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: result.content),
            ));
          }

          // Stream tool call notifications so the client can see them.
          // Tool calls are sent as structured ToolCallSessionUpdate (not thought
          // updates), so the client (Paseo) renders them in the tool call UI
          // instead of cluttering the thinking block.
          for (final tc in result.toolCalls) {
            final locationInfo = _toolLocationsFor(tc.name, tc.arguments);

            await sendAcpUpdate(ToolCallSessionUpdate(
              toolCallId: tc.id,
              title: tc.name,
              status: ToolCallStatus.inProgress,
              rawInput: tc.arguments,
              kind: _toolKindFor(tc.name),
              locations: locationInfo,
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
              await sendAcpUpdate(AgentMessageChunkSessionUpdate(
                content: TextContentBlock(text: '🛑 Cancelled.'),
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

          // Send usage update after the round is complete
          await sendUsage();
        } else {
          // Text response — done
          if (result.content.isNotEmpty) {
            conv.addMessage(Message(
              role: 'assistant',
              content: result.content,
            ));
          }
          _notifyUpdates();

          stopwatch.stop();
          // Stream the final text response
          if (result.content.isNotEmpty) {
            await sendAcpUpdate(AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: result.content),
            ));
          }

          // Send final usage update with cumulative token counts — this
          // already communicates completion, tokens, and elapsed info to
          // the client, no need for a separate "Done" thought.
          await sendUsage();
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

  /// Build a short one-line summary of a tool result string for display
  /// in thinking updates (so the client sees what the last tool did).
  String _summarizeToolResult(String content) {
    final lines = content.split('\n').where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return '(empty)';
    var summary = lines.first.trim();
    if (summary.length > 80) {
      summary = '${summary.substring(0, 77)}...';
    }
    // Remove markdown formatting for the summary
    summary = summary.replaceAll(RegExp(r'[*_`#]'), '');
    return summary;
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
              '`/provider` - Show current provider (Zen/OpenRouter/LM Studio)\n'
              '`/provider <zen|openrouter|lmstudio>` - Switch provider\n'
              '`/new` - Start a new conversation\n'
              '`/list` - List all conversations\n'
              '`/switch <id>` - Switch to a conversation\n'
              '`/clear` - Clear current conversation\n'
              '`/acp` - Toggle ACP server status\n'
              '`/models` - List ALL available models\n'
              '`/prompt <text>` - Set per-conversation system prompt\n'
              '`/quit` - Exit the agent\n'
              '`/phobe` - Toggle phobe mode (remove pride theming)\n'
              '`/lmstudio` - Re-fetch LM Studio models and list them\n'
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
          // Check all model lists (Zen, OpenRouter, and LM Studio)
          final inZen = ZenModels.get(modelId) != null;
          final inOr = ZenModels.openrouterGet(modelId) != null;
          final inLm = ZenModels.lmStudioGet(modelId) != null;
          if (inZen || inOr || inLm) {
            final prevProvider = currentProvider;
            await setModel(modelId);
            final newProvider = currentProvider;
            final providerNote = prevProvider != newProvider
                ? ' (auto-switched to **${_providerDisplayName(newProvider)}**)'
                : '';
            final msg = Message(
              role: 'assistant',
              content: '✅ Switched to `$modelId`$providerNote',
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
        final providerName = _providerDisplayName(currentProvider);
        final buffer = StringBuffer();
        buffer.writeln('**Available Models:**\n');
        buffer.writeln('_Current provider: `$providerName` — '
            'switch via `/provider <zen|openrouter|lmstudio>`_');
        buffer.writeln('');

        // Zen models section
        buffer.writeln('**Zen API:**');
        for (final model in ZenModels.all) {
          final active = model.id == ai.currentModel ? ' ◀' : '';
          buffer.writeln('- `${model.id}` (${model.provider}, Zen)$active');
        }

        buffer.writeln('');
        // OpenRouter models section
        buffer.writeln('**OpenRouter:**');
        for (final model in ZenModels.openrouterAll) {
          final active = model.id == ai.currentModel ? ' ◀' : '';
          buffer.writeln('- `${model.id}` (${model.provider}, OpenRouter)$active');
        }

        buffer.writeln('');
        // LM Studio models section
        buffer.writeln('**LM Studio:**');
        for (final model in ZenModels.lmStudioAll) {
          final active = model.id == ai.currentModel ? ' ◀' : '';
          buffer.writeln('- `${model.id}` (${model.provider}, LM Studio)$active');
        }
        _activeConv!.addMessage(Message(role: 'assistant', content: buffer.toString()));
        break;

      case '/provider':
        if (parts.length > 1) {
          final target = parts[1].toLowerCase();
          if (target == 'openrouter') {
            if (ai is OpenRouterAiService) {
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '⚠️ Already using OpenRouter (`${ai.currentModel}`)',
              ));
            } else {
              await switchToOpenrouter();
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '✅ Switched to **OpenRouter** (`${ai.currentModel}`)\n'
                    'Use `/models` to see available models, `/model <id>` to select one.',
              ));
            }
          } else if (target == 'lmstudio' || target == 'lm_studio') {
            if (ai is LmStudioAiService) {
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '⚠️ Already using LM Studio (`${ai.currentModel}`)',
              ));
            } else {
              await switchToLmStudio();
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '✅ Switched to **LM Studio** (`${ai.currentModel}`)\n'
                    'Use `/models` to see available models, `/model <id>` to select one.\n'
                    'Make sure LM Studio is running on ${config.lmStudioEndpoint}.',
              ));
            }
          } else if (target == 'zen') {
            if (ai is ZenAiService) {
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '⚠️ Already using Zen (`${ai.currentModel}`)',
              ));
            } else {
              await switchToZen();
              _activeConv!.addMessage(Message(
                role: 'assistant',
                content: '✅ Switched to **Zen** (`${ai.currentModel}`)\n'
                    'Use `/models` to see available models, `/model <id>` to select one.',
              ));
            }
          } else {
            _activeConv!.addMessage(Message(
              role: 'assistant',
              content: '⚠️ Unknown provider: `$target`. Use `zen`, `openrouter`, or `lmstudio`.',
            ));
          }
        } else {
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '**Current provider:** `${_providerDisplayName(currentProvider)}`\n'
                '**Current model:** `${ai.currentModel}`\n\n'
                'Use `/provider <zen|openrouter|lmstudio>` to switch.',
          ));
        }
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

      case '/lmstudio':
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '🔄 Re-fetching LM Studio models from `${config.lmStudioEndpoint}`...',
        ));
        _notifyUpdates();
        // Re-fetch models
        final oldCount = ZenModels.lmStudioAll.length;
        try {
          await refreshLmStudioModels();
        } catch (_) {}
        final newCount = ZenModels.lmStudioAll.length;
        final modelsList = ZenModels.lmStudioAll
            .map((m) => '  - `${m.id}`')
            .join('\n');
        final changed = oldCount != newCount ? ' (was $oldCount before)' : '';
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '**LM Studio Models**$changed:\n\n$modelsList\n\n'
              'Endpoint: `${config.lmStudioEndpoint}`\n'
              'Use `/model <id>` to select one, or select from Paseo\'s dropdown.',
        ));
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
        final providerName = _providerDisplayName(currentProvider);
        _activeConv!.addMessage(Message(
          role: 'assistant',
          content: '**Configuration:**\n\n'
              '- Provider: `$providerName`\n'
              '- Model: `${ai.currentModel}`\n'
              '- Zen endpoint: `${config.zenEndpoint}`\n'
              '- OpenRouter endpoint: `${config.openrouterEndpoint}`\n'
              '- LM Studio endpoint: `${config.lmStudioEndpoint}`\n'
              '- Zen API key: ${config.opencodeApiKey != null ? '✅ set' : '❌ not set'}\n'
              '- OpenRouter API key: ${config.openrouterApiKey != null ? '✅ set' : '❌ not set'}\n'
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
    conv.contextLimit = ZenModels.contextLimitFor(ai.currentModel);
    conv.contextTokens = 0;
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

  /// Set the active model and sync the conversation's context limit.
  /// If the model belongs to another provider, auto-switch providers.
  /// Call this instead of setting [ai.currentModel] directly to keep
  /// the context indicator accurate.
  ///
  /// Returns `true` if the model was switched successfully (or was
  /// already on the right provider), `false` if the provider switch
  /// failed.
  Future<bool> setModel(String modelId) async {
    // Auto-switch provider if needed
    final inZen = ZenModels.get(modelId) != null;
    final inOr = ZenModels.openrouterGet(modelId) != null;
    final inLm = ZenModels.lmStudioGet(modelId) != null;
    try {
      if (inOr && ai is! OpenRouterAiService && !isUsingAcp) {
        if (_openrouterFallback != null) {
          ai = _openrouterFallback!;
          _openrouterFallback = null;
        } else {
          await switchToOpenrouter();
        }
      } else if (inLm && ai is! LmStudioAiService && !isUsingAcp) {
        if (_lmStudioFallback != null) {
          ai = _lmStudioFallback!;
          _lmStudioFallback = null;
        } else {
          await switchToLmStudio();
        }
      } else if (inZen && ai is! ZenAiService && !isUsingAcp) {
        if (_zenFallback != null) {
          ai = _zenFallback!;
          _zenFallback = null;
        } else {
          await switchToZen();
        }
      }
    } catch (e) {
      return false;
    }
    ai.currentModel = modelId;
    if (_activeConv != null) {
      _activeConv!.contextLimit = ZenModels.contextLimitFor(modelId);
    }
    return true;
  }
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
    } else if (ai is LmStudioAiService) {
      _lmStudioFallback = ai as LmStudioAiService;
    }
    ai = AcpAiService(config: config, conn: conn);
    _notifyUpdates();
  }

  /// Disconnect from the remote ACP server and restore the previous provider.
  Future<void> disconnectFromAcp() async {
    if (_acpConnection != null) {
      await _acpConnection!.disconnect();
      _acpConnection = null;
    }
    // Restore the fallback, preferring OpenRouter > LM Studio > Zen
    if (_openrouterFallback != null) {
      ai = _openrouterFallback!;
      _openrouterFallback = null;
    } else if (_lmStudioFallback != null) {
      ai = _lmStudioFallback!;
      _lmStudioFallback = null;
    } else {
      ai = _zenFallback ?? ZenAiService(config: config);
    }
    _zenFallback = null;
    _notifyUpdates();
  }

  // ─── Provider switching (Zen ↔ OpenRouter) ──────────────────────────

  /// Which AI provider is currently active.
  AiProvider get currentProvider {
    if (ai is OpenRouterAiService) return AiProvider.openrouter;
    if (ai is LmStudioAiService) return AiProvider.lmstudio;
    if (ai is ZenAiService) return AiProvider.zen;
    // ACP or other — check the fallbacks
    if (_openrouterFallback != null) return AiProvider.openrouter;
    if (_lmStudioFallback != null) return AiProvider.lmstudio;
    return AiProvider.zen;
  }

  /// Switch to OpenRouter provider.
  Future<void> switchToOpenrouter() async {
    if (ai is OpenRouterAiService) return; // already there
    // Save current non-ACP service as fallback
    if (ai is ZenAiService) {
      _zenFallback = ai as ZenAiService;
    } else if (ai is LmStudioAiService) {
      _lmStudioFallback = ai as LmStudioAiService;
    }
    // Create or reuse existing OpenRouter service
    if (_openrouterFallback != null) {
      ai = _openrouterFallback!;
      _openrouterFallback = null;
    } else {
      ai = OpenRouterAiService(config: config);
      // Fetch models
      try {
        await (ai as OpenRouterAiService).fetchModels();
      } catch (_) {}
    }
    _notifyUpdates();
  }

  /// Switch to Zen provider.
  Future<void> switchToZen() async {
    if (ai is ZenAiService) return; // already there
    // Save current non-ACP service as fallback
    if (ai is OpenRouterAiService) {
      _openrouterFallback = ai as OpenRouterAiService;
    } else if (ai is LmStudioAiService) {
      _lmStudioFallback = ai as LmStudioAiService;
    }
    // Create or reuse existing Zen service
    if (_zenFallback != null) {
      ai = _zenFallback!;
      _zenFallback = null;
    } else {
      ai = ZenAiService(config: config);
      ai.fetchModels();
    }
    _notifyUpdates();
  }

  /// Switch to LM Studio provider.
  Future<void> switchToLmStudio() async {
    if (ai is LmStudioAiService) return; // already there
    // Save current non-ACP service as fallback
    if (ai is ZenAiService) {
      _zenFallback = ai as ZenAiService;
    } else if (ai is OpenRouterAiService) {
      _openrouterFallback = ai as OpenRouterAiService;
    }
    // Create or reuse existing LM Studio service
    if (_lmStudioFallback != null) {
      ai = _lmStudioFallback!;
      _lmStudioFallback = null;
    } else {
      ai = LmStudioAiService(config: config);
      try {
        await (ai as LmStudioAiService).fetchModels();
      } catch (_) {}
    }
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

    // Ensure context limit matches current model
    conv.contextLimit = ZenModels.contextLimitFor(ai.currentModel);
    // If loaded from an older save without contextTokens, estimate them
    if (conv.contextTokens == 0) {
      conv.contextTokens = conv.estimateContextTokens();
    }

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
  Future<bool> onSetModel(String modelId) async {
    return await setModel(modelId);
  }

  @override
  Map<String, dynamic> onInitialize() {
    return {
      'server_name': 'utopic-agent',
      'server_version': '1.0.0',
      'model': ai.currentModel,
    };
  }

  @override
  Future<Map<String, dynamic>> onRestart() async {
    // Cancel any in-flight agent work (AI HTTP requests, tool calls)
    cancel();

    // Wipe all conversations — we're starting clean
    _conversations.clear();
    _activeConv = null;
    _acpSessions.clear();
    _acpSessionToConvId.clear();

    // Re-initialize with a fresh welcome state
    await initialize();

    return onInitialize();
  }

  @override
  Future<Map<String, dynamic>> onNewSession(String cwd) async {
    final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';

    // If LM Studio only has the default model, try to re-fetch now
    // (the remote server might have been down during initialize()).
    if (ZenModels.lmStudioAll.length <= 1 &&
        ZenModels.lmStudioAll.any((m) => m.id == 'local-model')) {
      try {
        final lm = LmStudioAiService(config: config);
        await lm.fetchModels().timeout(const Duration(seconds: 8));
      } catch (_) {
        // Fine, use what we have
      }
    }

    // Create a conversation using the ACP session ID directly as its ID.
    // This ensures the conversation file on disk matches the ID that Paseo
    // uses in session/load and session/resume requests — critical for
    // resume to work across restarts.
    final conv = Conversation(
      id: sessionId,
      title: 'ACP Session',
      contextLimit: ZenModels.contextLimitFor(ai.currentModel),
    );
    conv.addMessage(Message(
      role: 'system',
      content: buildSystemPrompt(),
    ));
    _conversations.add(conv);
    _activeConv = conv;
    _notifyUpdates();
    _activeConversationController.add(conv);

    // Register the mapping (identity mapping — sessionId == conv.id)
    _acpSessionToConvId[sessionId] = conv.id;

    // Persist immediately so even an empty session appears in session/list
    // and can be resumed after a restart.
    try {
      _sessionStore.save(conv);
    } catch (_) {}

    return {
      'id': sessionId,
      'cwd': cwd,
      'model': ai.currentModel,
      'models': _buildModelList(),
    };
  }

  /// Build the combined model list (Zen + OpenRouter + LM Studio, dedup'd).
  /// Used for ACP session/new responses and config updates.
  List<Map<String, dynamic>> _buildModelList() {
    final seen = <String>{};
    final allModels = <Map<String, dynamic>>[];
    for (final m in ZenModels.all) {
      seen.add(m.id);
      allModels.add({
        'id': m.id,
        'name': m.displayName,
        'description': '${m.provider} · ${m.contextLimit ~/ 1000}K context',
        'contextLimit': m.contextLimit,
      });
    }
    for (final m in ZenModels.openrouterAll) {
      if (!seen.contains(m.id)) {
        seen.add(m.id);
        allModels.add({
          'id': m.id,
          'name': m.displayName,
          'description': 'OpenRouter · ${m.contextLimit ~/ 1000}K context',
          'contextLimit': m.contextLimit,
        });
      }
    }
    for (final m in ZenModels.lmStudioAll) {
      if (!seen.contains(m.id)) {
        seen.add(m.id);
        allModels.add({
          'id': m.id,
          'name': m.displayName,
          'description': 'LM Studio · ${m.contextLimit ~/ 1000}K context',
          'contextLimit': m.contextLimit,
        });
      }
    }
    return allModels;
  }

  /// Build [ModelInfo] list from [ZenModels] for ACP session updates.
  List<ModelInfo> _buildModelInfos() {
    return _buildModelList().map((m) {
      final contextLimit = m['contextLimit'] as int?;
      return ModelInfo(
        modelId: m['id'] as String,
        name: m['name'] as String,
        description: m['description'] as String?,
        meta: contextLimit != null ? {'contextLimit': contextLimit} : null,
      );
    }).toList();
  }

  /// Notify all active ACP sessions that the model list has changed.
  /// Pushes a [ConfigOptionUpdate] so the client (e.g. Paseo) can refresh
  /// its model dropdown. Also sends a [SessionInfoUpdate] as a signal.
  Future<void> _notifyAcpModelUpdate() async {
    if (_acpSessions.isEmpty) return;

    final models = _buildModelInfos();
    if (models.isEmpty) return;

    for (final entry in _acpSessions.entries) {
      try {
        // Send model list as a config option update (protocol-correct way
        // to communicate available choices to the client)
        await entry.value.sessionUpdate(SessionNotification(
          sessionId: entry.key,
          update: ConfigOptionUpdate(
            configOptions: [
              SessionConfigOption(
                id: 'available_models',
                name: 'Available Models',
                description:
                    '${models.length} models available across Zen, OpenRouter, and LM Studio',
                type: 'select',
                currentValue: ai.currentModel,
                options: UngroupedSessionConfigSelectOptions(
                  options: models
                      .map((m) => SessionConfigSelectOption(
                            value: m.modelId,
                            name: m.name,
                            description: m.description,
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ));
        // Also update the session model state via a model info update
        await entry.value.sessionUpdate(SessionNotification(
          sessionId: entry.key,
          update: SessionInfoUpdate(
            title: 'Utopic · ${ai.currentModel}',
            updatedAt: DateTime.now().toIso8601String(),
          ),
        ));
      } catch (e) {
        stderr.writeln('[utopic] ACP model update error: $e');
      }
    }
  }

  /// Try to re-fetch LM Studio models, then notify ACP clients of the update.
    /// Try to re-fetch LM Studio models, then notify ACP clients of the update.
  Future<void> refreshLmStudioModels() async {
    try {
      final lm = LmStudioAiService(config: config);
      await lm.fetchModels().timeout(const Duration(seconds: 10));
      final lmCount = ZenModels.lmStudioAll.length;
      if (lmCount > 1 || !ZenModels.lmStudioAll.any((m) => m.id == 'local-model')) {
        stderr.writeln('[utopic] LM Studio models refreshed: $lmCount model(s) loaded');
        _notifyUpdates();
        // Notify ACP sessions so Paseo's model dropdown can update
        unawaited(_notifyAcpModelUpdate());
      }
    } catch (e) {
      stderr.writeln('[utopic] LM Studio refresh failed: $e');
    }
  }

  @override
  Future<Map<String, dynamic>?> onLoadSession(
    String sessionId, {
    AgentSideConnection? connection,
  }) async {
    // Look up the conversation by ACP session ID first, then by conv ID
    final convId = _acpSessionToConvId[sessionId] ?? sessionId;

    // Check in-memory conversations first (fast path — same process)
    Conversation? conv;
    try {
      conv = _conversations.firstWhere((c) => c.id == convId);
    } catch (_) {}

    // Fall back to disk
    if (conv == null) {
      conv = _sessionStore.load(convId);
      if (conv == null) return null;
    }

    final c = conv;

    // Ensure context limit matches current model
    c.contextLimit = ZenModels.contextLimitFor(ai.currentModel);
    if (c.contextTokens == 0) {
      c.contextTokens = c.estimateContextTokens();
    }

    // Replace or add to conversations list
    final idx = _conversations.indexWhere((c2) => c2.id == c.id);
    if (idx >= 0) {
      _conversations[idx] = c;
    } else {
      _conversations.add(c);
    }
    _activeConv = c;
    _notifyUpdates();
    _activeConversationController.add(c);

    // Register the mapping so onPrompt can find it
    _acpSessionToConvId[sessionId] = c.id;

    // Stream the conversation history back to the client (Paseo) via
    // session/update notifications so it can populate the chat view.
    // This is required by the ACP spec for session/load.
    if (connection != null) {
      for (final msg in c.messages) {
        if (msg.role == 'system') continue; // Skip system messages
        if (msg.role == 'tool') {
          // Stream tool results as tool call updates
          await connection.sessionUpdate(SessionNotification(
            sessionId: sessionId,
            update: ToolCallUpdateSessionUpdate(
              toolCallId: msg.toolCallId ?? 'replay_${msg.id}',
              title: 'tool',
              status: ToolCallStatus.completed,
              rawOutput: {
                'result': msg.content.length > 500
                    ? '${msg.content.substring(0, 500)}...'
                    : msg.content,
              },
            ),
          ));
        } else if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          // Stream the AI's commentary text first
          if (msg.content.isNotEmpty) {
            await connection.sessionUpdate(SessionNotification(
              sessionId: sessionId,
              update: AgentMessageChunkSessionUpdate(
                content: TextContentBlock(text: msg.content),
              ),
            ));
          }
          // Then stream each tool call as in-progress updates
          for (final tc in msg.toolCalls!) {
            await connection.sessionUpdate(SessionNotification(
              sessionId: sessionId,
              update: ToolCallSessionUpdate(
                toolCallId: tc['id'] as String? ?? 'replay_${msg.id}',
                title: tc['name'] as String? ?? 'tool',
                status: ToolCallStatus.inProgress,
                rawInput: tc['arguments'] is String
                    ? jsonDecode(tc['arguments'] as String)
                    : tc['arguments'] as Map<String, dynamic>?,
                kind: _toolKindFor(tc['name'] as String? ?? ''),
              ),
            ));
            // Mark each as completed (we don't have the actual results linked)
            await connection.sessionUpdate(SessionNotification(
              sessionId: sessionId,
              update: ToolCallUpdateSessionUpdate(
                toolCallId: tc['id'] as String? ?? 'replay_${msg.id}',
                title: tc['name'] as String? ?? 'tool',
                status: ToolCallStatus.completed,
              ),
            ));
          }
        } else if (msg.role == 'assistant') {
          // Plain assistant text message
          await connection.sessionUpdate(SessionNotification(
            sessionId: sessionId,
            update: AgentMessageChunkSessionUpdate(
              content: TextContentBlock(text: msg.content),
            ),
          ));
        } else if (msg.role == 'user') {
          // User messages don't get streamed back as session updates
          // in the current ACP protocol — they're implicit in the history.
          // But we send them as thought updates so the client can reconstruct
          // the full conversation flow.
          await connection.sessionUpdate(SessionNotification(
            sessionId: sessionId,
            update: AgentThoughtChunkSessionUpdate(
              content: TextContentBlock(text: '👤 **${msg.content.substring(0, msg.content.length.clamp(0, 200))}**'),
            ),
          ));
        }
      }

      // Send a final usage update so Paseo shows the context bar
      await connection.sessionUpdate(SessionNotification(
        sessionId: sessionId,
        update: UsageUpdate(
          size: c.contextLimit,
          used: c.contextTokens,
          cost: Cost(
            amount: c.contextTokens * 0.000001,
            currency: 'USD',
          ),
        ),
      ));
    }

    return {
      'id': sessionId,
      'model': ai.currentModel,
      'models': _buildModelList(),
    };
  }

  @override
  Future<Map<String, dynamic>?> onResumeSession(
    String sessionId, {
    AgentSideConnection? connection,
  }) async {
    // Same as onLoadSession but without streaming history.
    //
    // Since conversations created via ACP use the ACP session ID as their
    // conversation ID (see onNewSession), the identity fallback at the end
    // of the lookup chain handles both in-memory and on-disk cases.
    final convId = _acpSessionToConvId[sessionId] ?? sessionId;

    // Check in-memory conversations first (fast path — same process)
    try {
      final conv = _conversations.firstWhere((c) => c.id == convId);
      _activeConv = conv;
      _notifyUpdates();
      _activeConversationController.add(conv);

      // Re-register the mapping so subsequent prompts find this conv
      _acpSessionToConvId[sessionId] = conv.id;

      return Future.value({
        'id': sessionId,
        'model': ai.currentModel,
        'models': _buildModelList(),
      });
    } catch (_) {}

    // Fall back to disk — load the conversation and set it as active
    // so the next prompt can find it in-memory.
    final loaded = _sessionStore.load(convId);
    if (loaded == null) return null;

    // Ensure context limit matches current model
    loaded.contextLimit = ZenModels.contextLimitFor(ai.currentModel);
    if (loaded.contextTokens == 0) {
      loaded.contextTokens = loaded.estimateContextTokens();
    }

    // Add or replace in conversations list
    final idx = _conversations.indexWhere((c) => c.id == loaded.id);
    if (idx >= 0) {
      _conversations[idx] = loaded;
    } else {
      _conversations.add(loaded);
    }
    _activeConv = loaded;
    _notifyUpdates();
    _activeConversationController.add(loaded);

    // Map the ACP session ID so subsequent prompts find it
    _acpSessionToConvId[sessionId] = loaded.id;

    return Future.value({
      'id': sessionId,
      'model': ai.currentModel,
      'models': _buildModelList(),
    });
  }

  @override
  Future<Map<String, dynamic>> onPrompt({
    required String sessionId,
    required String prompt,
    required AgentSideConnection connection,
  }) async {
    // Track this ACP session so we can push model list updates later
    _acpSessions[sessionId] = connection;

    // Find conversation by ACP session ID or conversation ID
    Conversation? conv;
    // First, check the ACP session → conversation ID mapping
    final mappedId = _acpSessionToConvId[sessionId];
    if (mappedId != null) {
      try {
        conv = _conversations.firstWhere((c) => c.id == mappedId);
      } catch (_) {}
    }
    // Fall back to matching by conversation ID directly
    if (conv == null) {
      try {
        conv = _conversations.firstWhere((c) => c.id == sessionId);
      } catch (_) {}
    }
    // Last resort: use the most recent conversation
    if (conv == null) {
      if (_conversations.isNotEmpty) {
        conv = _conversations.last;
      } else {
        conv = Conversation(title: 'ACP Session');
        _conversations.add(conv);
      }
    }

    // Sync _activeConv to this conversation so slash commands (which use
    // _activeConv internally) operate on the right conversation.
    _activeConv = conv;

    // Ensure system prompt for new conversations
    if (conv.messageCount == 0) {
      conv.addMessage(Message(
        role: 'system',
        content: buildSystemPrompt(),
      ));
    }

    conv.addMessage(Message(role: 'user', content: prompt));
    _notifyUpdates();

    // Handle slash commands (e.g. /models, /model, /provider) through the
    // command handler so they work the same whether sent via TUI or ACP.
    if (prompt.startsWith('/')) {
      await _handleCommand(prompt);
      // Send the response as a session update so Paseo sees it
      final lastMsg = conv.messages.last;
      if (lastMsg.content.isNotEmpty) {
        await connection.sessionUpdate(SessionNotification(
          sessionId: sessionId,
          update: AgentMessageChunkSessionUpdate(
            content: TextContentBlock(text: lastMsg.content),
          ),
        ));
      }
      // Save after slash command too, so /model, /provider etc. changes
      // persist alongside the conversation state.
      try {
        _sessionStore.save(conv);
      } catch (_) {}
      return {
        'inputTokens': 0,
        'outputTokens': 0,
      };
    }

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

    // Save the conversation to disk after every exchange so it can be
    // resumed later, even if the process restarts.
    try {
      _sessionStore.save(conv);
    } catch (_) {}

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
    // Abort any in-flight AI HTTP request so we stop waiting immediately
    // instead of waiting for the request to complete.
    ai.cancel();
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