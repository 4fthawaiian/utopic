import 'dart:io';
import 'package:path/path.dart' as path;
import 'tool.dart';

class WriteTool extends Tool {
  @override
  String get name => 'write';

  @override
  String get description => 'Create a new file or completely overwrite an existing file. '
      'Use this for creating new files or when the edit tool cannot make the needed changes. '
      'Automatically creates parent directories if they do not exist.';

  @override
  List<String> get required => ['path', 'content'];

  @override
  Map<String, dynamic> get parameters => {
    'path': {
      'type': 'string',
      'description': 'Path where to write the file',
    },
    'content': {
      'type': 'string',
      'description': 'The full content to write to the file',
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final p = args['path'] as String? ?? '';
    final content = args['content'] as String? ?? '';

    if (p.isEmpty) return 'Error: path is required';
    if (content.isEmpty) return 'Error: content is required';

    final file = File(path.normalize(p));

    try {
      // Create parent directories
      await file.parent.create(recursive: true);
      await file.writeAsString(content);

      final size = content.length;
      return '✅ Wrote $p ($size bytes)';
    } catch (e) {
      return 'Error writing $p: $e';
    }
  }
}
