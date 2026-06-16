import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/conversation.dart';

/// Persists conversations to `~/.config/utopic/sessions/<id>.json`.
///
/// Auto-creates the sessions directory on first save.
/// Each conversation is stored as one JSON file.
class SessionStore {
  final String _sessionsDir;

  SessionStore({String? sessionsDir})
      : _sessionsDir = sessionsDir ??
            path.join(
              Platform.environment['HOME'] ?? '.',
              '.config',
              'utopic',
              'sessions',
            );

  String get sessionsDir => _sessionsDir;

  /// Ensure the sessions directory exists.
  void _ensureDir() {
    final dir = Directory(_sessionsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  /// File path for a conversation.
  String _filePath(String id) => path.join(_sessionsDir, '$id.json');

  /// Save a conversation to disk.
  void save(Conversation conv) {
    _ensureDir();
    final file = File(_filePath(conv.id));
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(conv.toJson()),
    );
  }

  /// Load a conversation from disk.
  Conversation? load(String id) {
    final file = File(_filePath(id));
    if (!file.existsSync()) return null;
    try {
      final content = file.readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return Conversation.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Delete a saved conversation.
  Future<void> delete(String id) async {
    final file = File(_filePath(id));
    if (file.existsSync()) await file.delete();
  }

  /// List all saved sessions with metadata (id + title + timestamps).
  /// Returns empty list if no sessions exist or directory doesn't exist.
  List<Map<String, dynamic>> list() {
    final dir = Directory(_sessionsDir);
    if (!dir.existsSync()) return [];

    final sessions = <Map<String, dynamic>>[];
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      try {
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        sessions.add({
          'id': json['id'] as String? ?? '',
          'title': json['title'] as String? ?? '(untitled)',
          'createdAt': json['createdAt'] as String?,
          'updatedAt': json['updatedAt'] as String?,
          'messageCount': (json['messages'] as List?)?.length ?? 0,
        });
      } catch (_) {
        // Skip corrupt files
      }
    }

    // Sort by updatedAt descending (most recent first)
    sessions.sort((a, b) {
      final aTime = a['updatedAt'] as String? ?? '';
      final bTime = b['updatedAt'] as String? ?? '';
      return bTime.compareTo(aTime);
    });

    return sessions;
  }
}
