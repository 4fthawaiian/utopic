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

  AcpAgent(this.connection, this.delegate);

  @override
  Future<InitializeResponse> initialize(InitializeRequest params) async {
    final info = delegate.onInitialize();
    return InitializeResponse(
      protocolVersion: params.protocolVersion,
      agentCapabilities: AgentCapabilities(
        sessionCapabilities: SessionCapabilities(
          list: SessionListCapabilities(),
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
    final result = delegate.onNewSession(params.cwd);

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
  Future<LoadSessionResponse>? loadSession(LoadSessionRequest params) => null;

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
          ResumeSessionRequest params) =>
      null;

  @override
  Future<Map<String, dynamic>>? extMethod(
          String method, Map<String, dynamic> params) =>
      null;

  @override
  Future<void>? extNotification(
          String method, Map<String, dynamic> params) =>
      null;
}

/// Delegate interface for [AcpAgent] — implemented by [AgentService].
abstract class AcpAgentDelegate {
  /// Called on `initialize`. Returns basic server info.
  Map<String, dynamic> onInitialize();

  /// Called on `session/new`. Returns session info map.
  Map<String, dynamic> onNewSession(String cwd);

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
}
