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
}