import 'dart:io';
import 'package:path/path.dart' as path;
import 'tool.dart';

class EditTool extends Tool {
  @override
  String get name => 'edit';

  @override
  String get description => 'Make precise edits to a file using exact text replacement. '
      'Each edit replaces a unique block of text with new content. '
      'Use for targeted changes without rewriting the whole file.';

  @override
  List<String> get required => ['path', 'oldText', 'newText'];

  @override
  Map<String, dynamic> get parameters => {
    'path': {
      'type': 'string',
      'description': 'Path to the file to edit',
    },
    'oldText': {
      'type': 'string',
      'description': 'The exact text to replace (must be unique in the file)',
    },
    'newText': {
      'type': 'string',
      'description': 'The replacement text',
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final p = args['path'] as String? ?? '';
    final oldText = args['oldText'] as String? ?? '';
    final newText = args['newText'] as String? ?? '';

    if (p.isEmpty) return 'Error: path is required';
    if (oldText.isEmpty) return 'Error: oldText is required';

    final file = File(path.normalize(p));
    if (!file.existsSync()) return 'Error: file not found: $p';

    try {
      String content;
      try {
        content = file.readAsStringSync();
      } catch (e) {
        return 'Error reading $p: $e';
      }

      final count = _countOccurrences(content, oldText);
      if (count == 0) return 'Error: oldText not found in $p';
      if (count > 1) return 'Error: oldText found $count times in $p (must be unique)';

      content = content.replaceFirst(oldText, newText);
      file.writeAsStringSync(content);

      return '✅ Edited $p (${oldText.length} chars → ${newText.length} chars)';
    } catch (e) {
      return 'Error editing $p: $e';
    }
  }

  int _countOccurrences(String text, String pattern) {
    int count = 0;
    int i = 0;
    while ((i = text.indexOf(pattern, i)) != -1) {
      count++;
      i += pattern.length;
    }
    return count;
  }
}
