import 'dart:convert';
import 'dart:math';

/// A message in a conversation
class Message {
  final String id;
  final String role; // 'user', 'assistant', 'system', 'tool'
  final String content;
  final DateTime timestamp;
  final String? toolCallId;
  final List<Map<String, dynamic>>? toolCalls;

  Message({
    String? id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.toolCallId,
    this.toolCalls,
  })  : id = id ?? _generateId(),
        timestamp = timestamp ?? DateTime.now();

  static String _generateId() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'msg_${base64Encode(bytes).replaceAll(RegExp(r'[/+=]'), '')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (toolCalls != null) 'toolCalls': toolCalls,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String?,
        role: json['role'] as String,
        content: json['content'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'] as String)
            : null,
        toolCallId: json['toolCallId'] as String?,
        toolCalls: (json['toolCalls'] as List?)
            ?.cast<Map<String, dynamic>>(),
      );

  @override
  String toString() => '[$role] $content';
}

/// A conversation between the user and AI agent
class Conversation {
  final String id;
  String title;
  final List<Message> messages;
  final DateTime createdAt;
  DateTime updatedAt;
  String? systemPromptOverride;

  /// The total context tokens consumed by this conversation's messages.
  /// Updated after each API call with the exact input token count,
  /// or estimated locally before the first call.
  int contextTokens = 0;

  /// The context window limit for the currently configured model.
  /// Set when the model changes or a conversation starts.
  int contextLimit = 128000;

  Conversation({
    String? id,
    this.title = 'New Conversation',
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.systemPromptOverride,
    this.contextTokens = 0,
    this.contextLimit = 128000,
  })  : id = id ?? _generateId(),
        messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static String _generateId() {
    final now = DateTime.now();
    final random = Random();
    return 'conv_${now.millisecondsSinceEpoch}_${random.nextInt(99999)}';
  }

  void addMessage(Message message) {
    messages.add(message);
    updatedAt = DateTime.now();
  }

  int get messageCount => messages.length;

  /// Rough token estimate for text, based on ~1 token per 4 chars
  /// but accounting for denser code/markup.
  /// Good enough for pre-API-call display. Actual counts come from API.
  static int estimateTokens(String text) {
    // ~1 token per 3.5 chars average (code + English mix)
    return (text.length / 3.5).ceil();
  }

  /// Serialize the conversation to plain text for token estimation
  /// before an API call is made.
  String serializeContext() {
    final parts = <String>[];
    for (final msg in messages) {
      parts.add('[$msg.role] ${msg.content}');
      if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        for (final tc in msg.toolCalls!) {
          parts.add('  [tool_call: ${tc['name']}] ${tc['arguments']}');
        }
      }
    }
    return parts.join('\n');
  }

  /// Estimate context tokens from the current conversation state.
  int estimateContextTokens() {
    return estimateTokens(serializeContext());
  }

  /// The proportion of the context window currently used (0.0 to 1.0).
  double get contextUsageFraction {
    if (contextLimit <= 0) return 0.0;
    return (contextTokens / contextLimit).clamp(0.0, 1.0);
  }

  /// Formatted context usage string like "45%" or "92K/200K".
  String get contextSummary {
    final pct = (contextUsageFraction * 100).round();
    final usedK = (contextTokens / 1000).round();
    final limitK = (contextLimit / 1000).round();
    if (limitK > 0) {
      return '$pct%  (${usedK}K/${limitK}K)';
    }
    return '$pct%  (${usedK}K)';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'systemPromptOverride': systemPromptOverride,
        'contextTokens': contextTokens,
        'contextLimit': contextLimit,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final conv = Conversation(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'New Conversation',
      messages: (json['messages'] as List? ?? [])
          .map((m) => Message.fromJson(m as Map<String, dynamic>))
          .toList(),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
      systemPromptOverride: json['systemPromptOverride'] as String?,
      contextTokens: json['contextTokens'] as int? ?? 0,
      contextLimit: json['contextLimit'] as int? ?? 128000,
    );
    return conv;
  }
}