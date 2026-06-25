import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../acp/acp_dart_client.dart';
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

    final response = await _client
        .post(
          Uri.parse('${config.zenEndpoint}/v1/responses'),
          headers: {
            'Content-Type': 'application/json',
            if (config.opencodeApiKey != null)
              'Authorization': 'Bearer ${config.opencodeApiKey}',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));

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
// OpenRouterAiService — calls the OpenRouter Chat Completions API
// ============================================================================

class OpenRouterAiService extends AiService {
  final http.Client _client;
  String? _currentModel;

  OpenRouterAiService({required super.config, http.Client? client})
      : _client = client ?? http.Client();

  @override
  String get currentModel =>
      _currentModel ?? config.defaultOpenrouterModel;

  @override
  set currentModel(String model) => _currentModel = model;

  /// Build standard Chat Completions messages from a conversation.
  List<Map<String, dynamic>> _buildMessages(Conversation conversation) {
    final messages = <Map<String, dynamic>>[];

    for (final msg in conversation.messages) {
      if (msg.role == 'system') {
        messages.add({'role': 'system', 'content': msg.content});
      } else if (msg.role == 'tool') {
        messages.add({
          'role': 'tool',
          'tool_call_id': msg.toolCallId ?? '',
          'content': msg.content,
        });
      } else if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        messages.add({
          'role': 'assistant',
          'content': msg.content.isNotEmpty ? msg.content : null,
          'tool_calls': msg.toolCalls!.map((tc) => {
            'id': tc['id'],
            'type': 'function',
            'function': {
              'name': tc['name'],
              'arguments': tc['arguments'] is String
                  ? tc['arguments']
                  : jsonEncode(tc['arguments']),
            },
          }).toList(),
        });
      } else {
        messages.add({'role': msg.role, 'content': msg.content});
      }
    }

    return messages;
  }

  @override
  Future<AiResult> complete({
    required Conversation conversation,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraParams,
  }) async {
    final modelId = currentModel;
    final startTime = DateTime.now();

    final messages = _buildMessages(conversation);
    // OpenRouter uses the Chat Completions API format, which requires
    // tool definitions to be wrapped in a `function` field.
    // Convert from the flat Responses API format used internally.
    final chatTools = tools
        ?.map((t) => _toolToChatFormat(t))
        .toList();

    final body = <String, dynamic>{
      'model': modelId,
      'messages': messages,
      'max_tokens': 8192,
      if (chatTools != null && chatTools.isNotEmpty) 'tools': chatTools,
      if (chatTools != null && chatTools.isNotEmpty) 'tool_choice': 'auto',
      ...?extraParams,
    };

    final apiKey = config.openrouterApiKey;
    if (apiKey == null || apiKey.isEmpty) {
      throw HttpException(
        'OpenRouter API key not configured. '
        'Set openrouter_api_key in config or OPENROUTER_API_KEY env var.',
      );
    }

    final response = await _client
        .post(
          Uri.parse('${config.openrouterEndpoint}/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
            'HTTP-Referer': 'https://github.com/utopic-agent/utopic',
            'X-Title': 'Utopic Agent',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      final detail = _parseOpenrouterError(response.body);
      throw HttpException(
        'OpenRouter API error (${response.statusCode}): $detail',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = _extractChatContent(data);
    final toolCalls = _extractChatToolCalls(data);
    final usage = data['usage'] as Map<String, dynamic>?;

    return AiResult(
      content: content,
      model: data['model'] as String? ?? modelId,
      inputTokens: usage?['prompt_tokens'] as int? ?? 0,
      outputTokens: usage?['completion_tokens'] as int? ?? 0,
      duration: duration,
      toolCalls: toolCalls,
    );
  }

  @override
  Future<List<ZenModel>> fetchModels() async {
    try {
      final apiKey = config.openrouterApiKey;
      final response = await _client.get(
        Uri.parse('${config.openrouterEndpoint}/models'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final apiModels = data['data'] as List? ?? [];
        ZenModels.mergeOpenrouterModels(
          apiModels.cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // Fall back to defaults
    }

    return ZenModels.openrouterAll;
  }

  List<AiToolCall> _extractChatToolCalls(Map<String, dynamic> data) {
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return [];

    final message = choices[0] as Map<String, dynamic>?;
    if (message == null) return [];

    final msg = message['message'] as Map<String, dynamic>?;
    if (msg == null) return [];

    final toolCallsRaw = msg['tool_calls'] as List?;
    if (toolCallsRaw == null || toolCallsRaw.isEmpty) return [];

    return toolCallsRaw.map((tc) {
      final func = tc['function'] as Map<String, dynamic>? ?? {};
      final argsStr = func['arguments'] as String? ?? '{}';
      Map<String, dynamic> args;
      try {
        args = jsonDecode(argsStr) as Map<String, dynamic>;
      } catch (_) {
        args = {};
      }
      return AiToolCall(
        id: tc['id'] as String? ?? '',
        name: func['name'] as String? ?? '',
        arguments: args,
      );
    }).toList();
  }

  String _extractChatContent(Map<String, dynamic> data) {
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';

    final first = choices[0] as Map<String, dynamic>?;
    if (first == null) return '';

    final message = first['message'] as Map<String, dynamic>?;
    if (message == null) return '';

    return message['content'] as String? ?? '';
  }

  /// Convert a tool from the internal flat format (Responses API style)
  /// to the Chat Completions API format (with `function` wrapper).
  ///
  /// Input:  {type: "function", name: "read", description: "...", parameters: {...}}
  /// Output: {type: "function", function: {name: "read", description: "...", parameters: {...}}}
  Map<String, dynamic> _toolToChatFormat(Map<String, dynamic> tool) {
    return {
      'type': 'function',
      'function': {
        'name': tool['name'],
        'description': tool['description'],
        'parameters': tool['parameters'],
      },
    };
  }

  String _parseOpenrouterError(String body) {
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
// LmStudioAiService — calls a local LM Studio instance via the
// OpenAI-compatible Chat Completions API (http://localhost:1234/v1)
// ============================================================================

class LmStudioAiService extends AiService {
  final http.Client _client;
  String? _currentModel;

  LmStudioAiService({required super.config, http.Client? client})
      : _client = client ?? http.Client();

  @override
  String get currentModel =>
      _currentModel ?? config.defaultLmStudioModel;

  @override
  set currentModel(String model) => _currentModel = model;

  /// Build standard Chat Completions messages from a conversation.
  List<Map<String, dynamic>> _buildMessages(Conversation conversation) {
    final messages = <Map<String, dynamic>>[];

    for (final msg in conversation.messages) {
      if (msg.role == 'system') {
        messages.add({'role': 'system', 'content': msg.content});
      } else if (msg.role == 'tool') {
        messages.add({
          'role': 'tool',
          'tool_call_id': msg.toolCallId ?? '',
          'content': msg.content,
        });
      } else if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        messages.add({
          'role': 'assistant',
          'content': msg.content.isNotEmpty ? msg.content : null,
          'tool_calls': msg.toolCalls!.map((tc) => {
            'id': tc['id'],
            'type': 'function',
            'function': {
              'name': tc['name'],
              'arguments': tc['arguments'] is String
                  ? tc['arguments']
                  : jsonEncode(tc['arguments']),
            },
          }).toList(),
        });
      } else {
        messages.add({'role': msg.role, 'content': msg.content});
      }
    }

    return messages;
  }

  /// Convert a tool from the internal flat format (Responses API style)
  /// to the Chat Completions API format (with `function` wrapper).
  Map<String, dynamic> _toolToChatFormat(Map<String, dynamic> tool) {
    return {
      'type': 'function',
      'function': {
        'name': tool['name'],
        'description': tool['description'],
        'parameters': tool['parameters'],
      },
    };
  }

  @override
  Future<AiResult> complete({
    required Conversation conversation,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraParams,
  }) async {
    final modelId = currentModel;
    final startTime = DateTime.now();

    final messages = _buildMessages(conversation);
    final chatTools = tools
        ?.map((t) => _toolToChatFormat(t))
        .toList();

    final body = <String, dynamic>{
      'model': modelId,
      'messages': messages,
      'max_tokens': 8192,
      'stream': false,
      if (chatTools != null && chatTools.isNotEmpty) 'tools': chatTools,
      if (chatTools != null && chatTools.isNotEmpty) 'tool_choice': 'auto',
      ...?extraParams,
    };

    final response = await _client
        .post(
          Uri.parse('${config.lmStudioEndpoint}/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      final detail = _parseLmStudioError(response.body);
      throw HttpException(
        'LM Studio API error (${response.statusCode}): $detail',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = _extractChatContent(data);
    final toolCalls = _extractChatToolCalls(data);
    final usage = data['usage'] as Map<String, dynamic>?;

    return AiResult(
      content: content,
      model: data['model'] as String? ?? modelId,
      inputTokens: usage?['prompt_tokens'] as int? ?? 0,
      outputTokens: usage?['completion_tokens'] as int? ?? 0,
      duration: duration,
      toolCalls: toolCalls,
    );
  }

  @override
  Future<List<ZenModel>> fetchModels() async {
    try {
      final response = await _client.get(
        Uri.parse('${config.lmStudioEndpoint}/models'),
        headers: {
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final apiModels = data['data'] as List? ?? [];
        ZenModels.mergeLmStudioModels(
          apiModels.cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // Fall back to defaults
    }

    return ZenModels.lmStudioAll;
  }

  List<AiToolCall> _extractChatToolCalls(Map<String, dynamic> data) {
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return [];

    final message = choices[0] as Map<String, dynamic>?;
    if (message == null) return [];

    final msg = message['message'] as Map<String, dynamic>?;
    if (msg == null) return [];

    final toolCallsRaw = msg['tool_calls'] as List?;
    if (toolCallsRaw == null || toolCallsRaw.isEmpty) return [];

    return toolCallsRaw.map((tc) {
      final func = tc['function'] as Map<String, dynamic>? ?? {};
      final argsStr = func['arguments'] as String? ?? '{}';
      Map<String, dynamic> args;
      try {
        args = jsonDecode(argsStr) as Map<String, dynamic>;
      } catch (_) {
        args = {};
      }
      return AiToolCall(
        id: tc['id'] as String? ?? '',
        name: func['name'] as String? ?? '',
        arguments: args,
      );
    }).toList();
  }

  String _extractChatContent(Map<String, dynamic> data) {
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';

    final first = choices[0] as Map<String, dynamic>?;
    if (first == null) return '';

    final message = first['message'] as Map<String, dynamic>?;
    if (message == null) return '';

    return message['content'] as String? ?? '';
  }

  String _parseLmStudioError(String body) {
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
// AcpAiService — delegates to a remote ACP server via acp_dart
// ============================================================================

class AcpAiService extends AiService {
  final AcpDartConnection _conn;
  String? _currentModelId;

  AcpAiService({required super.config, required this._conn});

  /// Available models from the remote ACP server.
  List<Map<String, dynamic>> get availableModels =>
      _conn.availableModels.map((m) => m.toJson()).toList();

  @override
  String get currentModel => _currentModelId ?? serverName;

  @override
  set currentModel(String model) {
    _currentModelId = model;
    _conn.setModel(model).catchError((_) {});
  }

  /// The remote server name.
  String get serverName => _conn.serverName;

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

    final result = await _conn.complete(prompt);

    final duration = DateTime.now().difference(startTime);

    return AiResult(
      content: result['content'] as String? ?? '',
      model: result['model'] as String? ?? currentModel,
      inputTokens: result['inputTokens'] as int? ?? 0,
      outputTokens: result['outputTokens'] as int? ?? 0,
      duration: duration,
    );
  }

  @override
  Future<List<ZenModel>> fetchModels() async {
    return [];
  }
}