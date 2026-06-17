import 'dart:io';
import 'package:path/path.dart' as path;
import 'tool.dart';

class ReadTool extends Tool {
  @override
  String get name => 'read';

  @override
  String get description => 'Read the contents of a file or directory listing. '
      'Returns file contents for files, or a listing for directories.';

  @override
  List<String> get required => ['path'];

  @override
  Map<String, dynamic> get parameters => {
    'path': {
      'type': 'string',
      'description': 'Path to the file or directory to read',
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final p = args['path'] as String? ?? '';
    if (p.isEmpty) return 'Error: path is required';

    try {
      final normalized = path.normalize(p);
      final entity = FileSystemEntity.typeSync(normalized);

      if (entity == FileSystemEntityType.notFound) {
        return 'Error: not found: $p';
      }

      if (entity == FileSystemEntityType.directory) {
        final dir = Directory(normalized);
        final entries = dir.listSync().map((e) {
          final name = path.basename(e.path);
          final type = e is File ? 'file' : 'dir';
          return '  $type\t$name';
        }).toList();
        return 'Directory: $p\n${entries.join('\n')}';
      }

      // Regular file
      final file = File(normalized);
      final content = file.readAsStringSync();
      final lines = content.split('\n');
      if (lines.length > 2000) {
        return '${lines.take(2000).join('\n')}\n\n... [${lines.length - 2000} more lines]';
      }
      if (content.length > 50000) {
        return '${content.substring(0, 50000)}\n\n... [${content.length - 50000} more bytes]';
      }
      return content;
    } catch (e) {
      return 'Error reading $p: $e';
    }
  }
}
