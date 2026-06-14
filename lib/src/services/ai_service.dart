import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../acp/acp_client.dart';
import '../config/app_config.dart';
import '../models/conversation.dart';
import '../models/zen_models.dart';

/// A tool call requested by the AI.
class AiToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory AiToolCall.fromJson(Map<String, dynamic> json) {
    return AiToolCall(
      id: json['call_id'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      arguments: _parseArguments(json['arguments'] as String? ?? '{}'),
    );
  }

  static Map<String, dynamic> _parseArguments(String args) {
    try {
      return jsonDecode(args) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

/// Result from an AI completion.
class AiResult {
  final String content;
  final String model;
  final int inputTokens;
  final int outputTokens;
  final Duration duration;
  final List<AiToolCall> toolCalls;
  final bool hasToolCalls;

  AiResult({
    required this.content,
    required this.model,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.duration = Duration.zero,
    this.toolCalls = const [],
  }) : hasToolCalls = toolCalls.isNotEmpty;
}

/// Abstract AI service — provides [complete] for sending prompts and
/// [fetchModels] for discovering available models.
abstract class AiService {
  final AppConfig config;

  AiService({required this.config});

  /// The currently active model identifier.
  String get currentModel;
  set currentModel(String model);

  /// Send a completion request (non-streaming).
  Future<AiResult> complete({
    required Conversation conversation,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraParams,
  });

  /// Fetch available models from the provider.
  Future<List<ZenModel>> fetchModels();
}

// ============================================================================
// ZenAiService — calls the OpenCode Zen API (Responses API) over HTTP
// ============================================================================

class ZenAiService extends AiService {
  final http.Client _client;
  String? _currentModel;

  ZenAiService({required super.config, http.Client? client})
      : _client = client ?? http.Client();

  @override
  String get currentModel => _currentModel ?? config.defaultModel;

  @override
  set currentModel(String model) => _currentModel = model;

  /// Build the input array for the Responses API from a conversation.
  List<Map<String, dynamic>> _buildInput(Conversation conversation) {
    final input = <Map<String, dynamic>>[];

    for (final msg in conversation.messages) {
      if (msg.role == 'system') {
        input.add({'role': 'developer', 'content': msg.content});
      } else if (msg.role == 'tool') {
        input.add({
          'role': 'tool',
          'tool_call_id': msg.toolCallId ?? '',
          'content': msg.content,
        });
      } else if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        input.add({
          'role': 'assistant',
          'content': null,
          'tool_calls': msg.toolCalls!.map((tc) => {
            'id': tc['id'],
            'type': 'function',
            'function': {
              'name': tc['name'],
              'arguments': tc['arguments'],
            },
          }).toList(),
        });
      } else {
        input.add({'role': msg.role, 'content': msg.content});
      }
    }

    return input;
  }

  @override
  Future<AiResult> complete({
    required Conversation conversation,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraParams,
  }) async {
    final modelId = currentModel;
    final startTime = DateTime.now();

    final input = _buildInput(conversation);
    final body = <String, dynamic>{
      'model': modelId,
      'input': input,
      'max_output_tokens': 8192,
      'store': false,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      ...?extraParams,
    };

    final response = await _client.post(
      Uri.parse('${config.zenEndpoint}/v1/responses'),
      headers: {
        'Content-Type': 'application/json',
        if (config.opencodeApiKey != null)
          'Authorization': 'Bearer ${config.opencodeApiKey}',
      },
      body: jsonEncode(body),
    );

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      final detail = _parseError(response.body);
      throw HttpException(
        'Zen API error (${response.statusCode}): $detail',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = _extractContent(data);
    final toolCalls = _extractToolCalls(data);
    final usage = data['usage'] as Map<String, dynamic>?;

    return AiResult(
      content: content,
      model: data['model'] as String? ?? modelId,
      inputTokens: usage?['input_tokens'] as int? ?? 0,
      outputTokens: usage?['output_tokens'] as int? ?? 0,
      duration: duration,
      toolCalls: toolCalls,
    );
  }

  @override
  Future<List<ZenModel>> fetchModels() async {
    try {
      final response = await _client.get(
        Uri.parse('${config.zenEndpoint}/v1/models'),
        headers: {
          if (config.opencodeApiKey != null)
            'Authorization': 'Bearer ${config.opencodeApiKey}',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final apiModels = data['data'] as List? ?? [];
        ZenModels.fetchFromApi(apiModels.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // Fall back to defaults
    }

    return ZenModels.all;
  }

  List<AiToolCall> _extractToolCalls(Map<String, dynamic> data) {
    final output = data['output'] as List?;
    if (output == null || output.isEmpty) return [];

    final calls = <AiToolCall>[];
    for (final item in output) {
      if (item is Map<String, dynamic> && item['type'] == 'function_call') {
        calls.add(AiToolCall.fromJson(item));
      }
    }
    return calls;
  }

  String _extractContent(Map<String, dynamic> data) {
    final output = data['output'] as List?;
    if (output == null || output.isEmpty) return '';

    for (final item in output) {
      if (item is Map<String, dynamic> && item['type'] == 'message') {
        final content = item['content'] as List?;
        if (content == null || content.isEmpty) continue;
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final type = part['type'] as String?;
            if (type == 'thinking' || type == 'reasoning') continue;
            if (type == 'output_text') {
              var text = part['text'] as String? ?? '';
              text = text.replaceAll(
                RegExp(r' thinking.*? response', dotAll: true), '').trim();
              return text;
            }
          }
        }
      }
    }
    return '';
  }

  String _parseError(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      if (error != null) {
        return (error['message'] as String?) ?? body;
      }
    } catch (_) {}
    return body;
  }
}

// ============================================================================
// AcpAiService — delegates to a remote ACP server
//
// Uses the standard ACP protocol:
//   1. Initialize → discover server capabilities
//   2. session/new (or session/create) → create a conversation session
//   3. session/prompt → send a user prompt
//   4. session/update notifications → receive response text (agent_message_chunk)
//
// The session/prompt response itself ONLY contains stopReason + usage — never
// the text content. All actual text arrives via session/update notifications
// during the prompt turn.
// ============================================================================

class AcpAiService extends AiService {
  final AcpClient _client;
  String? _sessionId;
  String? _currentModelId;

  /// Model options advertised by the remote server, keyed by config option id.
  final Map<String, List<Map<String, dynamic>>> _configOptions = {};

  /// Collects text chunks during an active prompt turn.
  /// Non-null while a session/prompt is in flight.
  List<String>? _turnChunks;

  AcpAiService({required super.config, required this._client}) {
    _client.onNotification = _onNotification;
  }

  void _onNotification(String method, Map<String, dynamic>? params) {
    stderr.writeln('ACP notification: method=$method params=$params');
    if (method == 'session/update' && params != null) {
      final update = params['update'] as Map<String, dynamic>?;
      if (update == null) return;

      final kind = update['sessionUpdate'] as String?;

      // Capture config options (models, modes, etc.)
      if (kind == 'config_option_update') {
        final options = update['configOptions'] as List?;
        if (options != null) {
          _processConfigOptions(options);
        }
      }

      // Collect text content during a prompt turn.
      if (kind == 'agent_message_chunk' && _turnChunks != null) {
        // content can be a single ContentBlock map or a list of them
        final content = update['content'];
        if (content is Map<String, dynamic>) {
          _collectContentText(content);
        } else if (content is List) {
          for (final block in content) {
            if (block is Map<String, dynamic>) {
              _collectContentText(block);
            }
          }
        }
      }
    }
  }

  /// Extract text from a ContentBlock map if it is a text block.
  void _collectContentText(Map<String, dynamic> block) {
    if (block['type'] == 'text') {
      final text = block['text'] as String?;
      if (text != null && _turnChunks != null) {
        _turnChunks!.add(text);
      }
    }
  }

  /// Process config options from the ACP server, populating _configOptions.
  void _processConfigOptions(List options) {
    for (final opt in options) {
      if (opt is Map<String, dynamic>) {
        final id = opt['id'] as String?;
        if (id != null) {
          _configOptions[id] = List<Map<String, dynamic>>.from(
              (opt['options'] as List?)?.cast<Map<String, dynamic>>() ?? []);
          if (_currentModelId == null && opt['currentValue'] != null) {
            _currentModelId = opt['currentValue'] as String?;
          }
        }
      }
    }
    stderr.writeln('ACP: configOptions now: $_configOptions');
  }

  /// Available models from the remote ACP server (if it advertises them).
  List<Map<String, dynamic>> get availableModels =>
      _configOptions['model'] ?? [];

  /// Create a session so we can send prompts.
  /// Tries `session/new` (Devin-style) first, then `session/create` (ACP standard).
  Future<void> initSession() async {
    if (_sessionId != null) return;
    for (final method in ['session/new', 'session/create']) {
      try {
        stderr.writeln('ACP: trying $method');
        final session = await _client.call(method, params: {
          'cwd': Directory.current.path,
          'mcpServers': <Map<String, dynamic>>[],
        });
        stderr.writeln('ACP: session response: $session');
        _sessionId = (session['sessionId'] as String?) ??
            (session['id'] as String?) ??
            (session['session_id'] as String?) ??
            'default';

        // Some servers include config options directly in the session response
        final configOptions = session['configOptions'];
        if (configOptions is List) {
          stderr.writeln('ACP: configOptions from session response: $configOptions');
          _processConfigOptions(configOptions);
        }
        final configOption = session['configOption'];
        if (configOption is Map) {
          final list = [configOption];
          _processConfigOptions(list);
        }

        stderr.writeln('ACP: session created: $_sessionId');
        if (_sessionId != null) break;
      } catch (e) {
        stderr.writeln('ACP: $method failed: $e');
      }
    }
  }

  @override
  String get currentModel => _currentModelId ?? 'acp';

  @override
  set currentModel(String model) {
    _currentModelId = model;
    if (_sessionId != null) {
      _client.notify('session/set_config_option', params: {
        'sessionId': _sessionId,
        'optionId': 'model',
        'value': model,
      });
    }
  }

  /// The remote server name.
  String get serverName =>
      (_client.serverInfo?['server_name'] as String?) ?? 'acp';

  /// The underlying ACP client.
  AcpClient get client => _client;

  @override
  Future<AiResult> complete({
    required Conversation conversation,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraParams,
  }) async {
    final userMessages = conversation.messages
        .where((m) => m.role == 'user')
        .toList();
    final prompt = userMessages.isNotEmpty
        ? userMessages.last.content
        : '';

    final startTime = DateTime.now();

    // Ensure we have a session before sending a prompt.
    if (_sessionId == null) {
      await initSession();
    }

    // Start collecting notification chunks BEFORE sending the prompt
    // so we don't miss any that arrive before or with the response.
    _turnChunks = [];

    Map<String, dynamic>? result;
    try {
      result = await _client.call('session/prompt', params: {
        'sessionId': _sessionId,
        'prompt': [
          {'type': 'text', 'text': prompt},
        ],
      });
    } catch (e) {
      rethrow;
    } finally {
      _turnChunks = null;
    }

    final duration = DateTime.now().difference(startTime);

    // Join all notification text chunks collected during the prompt turn.
    final text = _turnChunks?.join() ?? '';
    _turnChunks = null;

    // Extract usage from the session/prompt response (some servers send it).
    int inputTokens = 0, outputTokens = 0;
    final usage = result['usage'];
    if (usage is Map<String, dynamic>) {
      inputTokens = (usage['inputTokens'] as int?) ??
                    (usage['input_tokens'] as int?) ?? 0;
      outputTokens = (usage['outputTokens'] as int?) ??
                     (usage['output_tokens'] as int?) ?? 0;
    }

    return AiResult(
      content: text,
      model: currentModel,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      duration: duration,
    );
  }

  @override
  Future<List<ZenModel>> fetchModels() async {
    // ACP servers don't expose a model list via the standard protocol.
    return [];
  }
}