import 'dart:async';
import 'package:acp_dart/acp_dart.dart';

/// Agent-side ACP handler — implements the [Agent] interface.
///
/// Wraps an [AcpAgentDelegate] to handle incoming client requests
/// (initialize, session/new, session/prompt, etc.) and streams
/// session updates back through [AgentSideConnection].
class AcpAgent implements Agent {
  final AgentSideConnection connection;
  final AcpAgentDelegate delegate;

  /// Tracks whether this agent has been initialized — subsequent
  /// `initialize` calls trigger a restart (full state reset).
  bool _initialized = false;

  AcpAgent(this.connection, this.delegate);

  @override
  Future<InitializeResponse> initialize(InitializeRequest params) async {
    if (_initialized) {
      // Re-initialization = restart signal.
      // Reset all state and reinit the agent service.
      await delegate.onRestart();
    }
    _initialized = true;

    final info = delegate.onInitialize();
    return InitializeResponse(
      protocolVersion: params.protocolVersion,
      agentCapabilities: AgentCapabilities(
        loadSession: true,
        sessionCapabilities: SessionCapabilities(
          list: SessionListCapabilities(),
          resume: SessionResumeCapabilities(),
        ),
        promptCapabilities: PromptCapabilities(),
        mcpCapabilities: McpCapabilities(),
      ),
      agentInfo: Implementation(
        name: info['server_name'] as String? ?? 'utopic-agent',
        version: info['server_version'] as String? ?? '1.0.0',
        title: info['model']?.toString(),
      ),
    );
  }

  @override
  Future<NewSessionResponse> newSession(NewSessionRequest params) async {
    final result = await delegate.onNewSession(params.cwd);

    // Build model info from available models, including context limit
    // in the _meta field so clients (like Paseo) can calculate
    // context-window percentage from UsageUpdate updates.
    final modelInfos = (result['models'] as List<dynamic>? ?? [])
        .map((m) {
          final map = m as Map<String, dynamic>;
          final contextLimit = map['contextLimit'] as int?;
          return ModelInfo(
            modelId: map['id'] as String,
            name: map['name'] as String,
            description: map['description'] as String?,
            meta: contextLimit != null
                ? {'contextLimit': contextLimit}
                : null,
          );
        })
        .toList();

    return NewSessionResponse(
      sessionId: result['id'] as String,
      models: modelInfos.isNotEmpty
          ? SessionModelState(
              availableModels: modelInfos,
              currentModelId: (result['model'] as String?) ?? modelInfos.first.modelId,
            )
          : null,
      modes: SessionModeState(
        availableModes: [
          SessionMode(id: 'code', name: 'Code', description: 'Standard coding mode'),
        ],
        currentModeId: 'code',
      ),
    );
  }

  @override
  Future<PromptResponse> prompt(PromptRequest params) async {
    // Extract text from content blocks
    final text = params.prompt
        .whereType<TextContentBlock>()
        .map((b) => b.text)
        .join('\n');

    final result = await delegate.onPrompt(
      sessionId: params.sessionId,
      prompt: text,
      connection: connection,
    );

    return PromptResponse(
      stopReason: StopReason.endTurn,
      usage: Usage(
        inputTokens: result['inputTokens'] as int? ?? 0,
        outputTokens: result['outputTokens'] as int? ?? 0,
        totalTokens: (result['inputTokens'] as int? ?? 0) +
            (result['outputTokens'] as int? ?? 0),
      ),
    );
  }

  @override
  Future<void> cancel(CancelNotification params) async {
    delegate.onCancel(params.sessionId);
  }

  @override
  Future<LoadSessionResponse>? loadSession(LoadSessionRequest params) async {
    // Pass the connection so the delegate can stream conversation history
    // as session/update notifications back to the client (Paseo).
    final result = await delegate.onLoadSession(
      params.sessionId,
      connection: connection,
    );
    if (result == null) {
      throw Exception('Session not found: ${params.sessionId}');
    }


    final modelInfos = _buildModelInfos(result);
    return LoadSessionResponse(
      models: modelInfos.isNotEmpty
          ? SessionModelState(
              availableModels: modelInfos,
              currentModelId: (result['model'] as String?) ??
                  modelInfos.first.modelId,
            )
          : null,
      modes: SessionModeState(
        availableModes: [
          SessionMode(id: 'code', name: 'Code', description: 'Standard coding mode'),
        ],
        currentModeId: 'code',
      ),
    );
  }

  @override
  Future<ListSessionsResponse>? unstableListSessions(
      ListSessionsRequest params) async {
    final sessions = delegate.onListSessions();
    return ListSessionsResponse(
      sessions: sessions
          .map((s) => SessionInfo(
                cwd: s['cwd'] as String? ?? '.',
                sessionId: s['id'] as String,
                title: s['title'] as String?,
                updatedAt: s['updated_at'] as String?,
              ))
          .toList(),
    );
  }

  @override
  Future<SetSessionModeResponse?>? setSessionMode(
      SetSessionModeRequest params) async {
    return SetSessionModeResponse();
  }

  @override
  Future<SetSessionConfigOptionResponse>? setSessionConfigOption(
      SetSessionConfigOptionRequest params) async {
    return SetSessionConfigOptionResponse(configOptions: []);
  }

  @override
  Future<SetSessionModelResponse?>? setSessionModel(
      SetSessionModelRequest params) async {
    // Actually set the model on the delegate so Paseo's model selector works
    await delegate.onSetModel(params.modelId);
    return SetSessionModelResponse();
  }

  @override
  Future<AuthenticateResponse?>? authenticate(
      AuthenticateRequest params) async {
    return AuthenticateResponse();
  }

  @override
  Future<ForkSessionResponse>? unstableForkSession(
          ForkSessionRequest params) =>
      null;

  @override
  Future<ResumeSessionResponse>? unstableResumeSession(
      ResumeSessionRequest params) async {
    final result = await delegate.onResumeSession(
      params.sessionId,
      connection: connection,
    );
    if (result == null) {
      throw Exception('Session not found: ${params.sessionId}');
    }

    final modelInfos = _buildModelInfos(result);
    return ResumeSessionResponse(
      models: modelInfos.isNotEmpty
          ? SessionModelState(
              availableModels: modelInfos,
              currentModelId: (result['model'] as String?) ??
                  modelInfos.first.modelId,
            )
          : null,
      modes: SessionModeState(
        availableModes: [
          SessionMode(id: 'code', name: 'Code', description: 'Standard coding mode'),
        ],
        currentModeId: 'code',
      ),
    );
  }

  /// Build model info list from a session result map.
  List<ModelInfo> _buildModelInfos(Map<String, dynamic> result) {
    final modelsList = (result['models'] as List<dynamic>? ?? [])
        .map((m) {
          final map = m as Map<String, dynamic>;
          final contextLimit = map['contextLimit'] as int?;
          return ModelInfo(
            modelId: map['id'] as String,
            name: map['name'] as String,
            description: map['description'] as String?,
            meta: contextLimit != null
                ? {'contextLimit': contextLimit}
                : null,
          );
        })
        .toList();
    return modelsList;
  }

  @override
  Future<Map<String, dynamic>>? extMethod(
          String method, Map<String, dynamic> params) =>
      null;

  @override
  Future<void>? extNotification(
          String method, Map<String, dynamic> params) async {
    // Handle `_restart` extension notification — Paseo can send this to
    // reset the agent state without killing the subprocess.
    if (method == '_restart') {
      await delegate.onRestart();
    }
  }
}

/// Delegate interface for [AcpAgent] — implemented by [AgentService].
abstract class AcpAgentDelegate {
  /// Called on `initialize`. Returns basic server info.
  Map<String, dynamic> onInitialize();

  /// Called on `session/new`. Returns session info map.
  Future<Map<String, dynamic>> onNewSession(String cwd);

  /// Called on `session/prompt`. Runs the agent loop and returns result.
  Future<Map<String, dynamic>> onPrompt({
    required String sessionId,
    required String prompt,
    required AgentSideConnection connection,
  });

  /// Called on `session/cancel`.
  void onCancel(String sessionId);

  /// Called on `session/list`. Returns list of session info maps.
  List<Map<String, dynamic>> onListSessions();

  /// Called on `session/load`. Loads a previously saved session and
  /// streams its conversation history as session updates.
  /// Returns the session info map (same shape as [onNewSession]),
  /// or `null` if the session is not found.
  ///
  /// The [connection] is provided so the delegate can stream conversation
  /// history messages back to the client via `session/update` notifications.
  Future<Map<String, dynamic>?> onLoadSession(
    String sessionId, {
    AgentSideConnection? connection,
  }) async => null;

  /// Called on `session/resume`. Resumes an existing session without
  /// replaying previous messages.
  /// Returns the session info map (same shape as [onNewSession]),
  /// or `null` if the session is not found.
  Future<Map<String, dynamic>?> onResumeSession(
    String sessionId, {
    AgentSideConnection? connection,
  }) async => null;

  /// Called on `session/set_model`. Sets the active model.
  /// Should return `true` on success, `false` if the model could not be set.
  /// Default returns `true` — subclasses can override.
  Future<bool> onSetModel(String modelId) async => true;

  /// Called on `initialize` (re-initialization) or the `_restart` extension
  /// notification. Resets all agent state — clears conversations, cancels
  /// in-flight work, and reinitializes with a fresh welcome message.
  ///
  /// Returns the same info map as [onInitialize] once restart is complete.
  Future<Map<String, dynamic>> onRestart();
}
