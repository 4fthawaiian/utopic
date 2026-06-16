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

  Conversation({
    String? id,
    this.title = 'New Conversation',
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.systemPromptOverride,
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'systemPromptOverride': systemPromptOverride,
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
    );
    return conv;
  }
}