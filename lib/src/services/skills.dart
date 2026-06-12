import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// A skill discovered from a SKILL.md file.
///
/// Follows the [Agent Skills Specification](https://agentskills.io/specification).
/// Skills are loaded progressively: metadata at init, full body on activation.
class Skill {
  /// Skill name (lowercase, hyphens, matches directory name).
  final String name;

  /// Description of what this skill does and when to use it.
  final String description;

  /// Absolute path to the SKILL.md file.
  final String filePath;

  /// Absolute path to the skill directory (parent of SKILL.md).
  final String directory;

  /// Optional license.
  final String? license;

  /// Optional compatibility requirements.
  final String? compatibility;

  /// Optional arbitrary metadata key-value pairs.
  final Map<String, String> metadata;

  /// Optional pre-approved tools (experimental in spec).
  final String? allowedTools;

  /// Full body content (loaded lazily on first access).
  String? _body;

  Skill._({
    required this.name,
    required this.description,
    required this.filePath,
    required this.directory,
    this.license,
    this.compatibility,
    this.metadata = const {},
    this.allowedTools,
  });

  /// Whether the full body has been loaded.
  bool get isLoaded => _body != null;

  /// The full SKILL.md body content. Loaded on first access.
  String get body {
    _body ??= _loadBody();
    return _body!;
  }

  String _loadBody() {
    try {
      final content = File(filePath).readAsStringSync();
      return _stripFrontmatter(content);
    } catch (_) {
      return '';
    }
  }

  /// Read a file relative to the skill directory (e.g. `references/REFERENCE.md`).
  String? readFile(String relativePath) {
    final target = File(path.join(directory, relativePath));
    if (!target.existsSync()) return null;
    try {
      return target.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// List files in a subdirectory (e.g. `references/`, `scripts/`).
  List<String> listFiles(String subDir) {
    final dir = Directory(path.join(directory, subDir));
    if (!dir.existsSync()) return [];
    return dir.listSync().map((e) => path.relative(e.path, from: directory)).toList();
  }

  /// Returns a relevance score (0-10) for a given user message.
  int relevance(String userMessage) {
    final msg = userMessage.toLowerCase();
    int score = 0;

    // Match on description keywords
    final descWords = description.toLowerCase().split(RegExp(r'\s+'));
    for (final word in descWords) {
      if (word.length > 3 && msg.contains(word)) {
        score += 2;
      }
    }

    // Match on name
    if (msg.contains(name.toLowerCase())) {
      score += 3;
    }

    // Bonus for explicit keyword mentions in description (quoted terms)
    final re = RegExp(r'"([^"]+)"');
    for (final match in re.allMatches(description)) {
      final phrase = match.group(1)!.toLowerCase();
      if (msg.contains(phrase)) {
        score += 5;
      }
    }

    return score.clamp(0, 10);
  }

  /// Validate a skill name against the Agent Skills spec.
  static String? validateName(String? name) {
    if (name == null || name.isEmpty) return 'name is required';
    if (name.length > 64) return 'name must be 64 characters or less';
    if (!RegExp(r'^[a-z0-9]').hasMatch(name[0])) {
      return 'name must start with a lowercase letter or digit';
    }
    if (!RegExp(r'[a-z0-9]$').hasMatch(name[name.length - 1])) {
      return 'name must end with a lowercase letter or digit';
    }
    if (name.contains('--')) return 'name must not contain consecutive hyphens';
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*[a-z0-9]$').hasMatch(name)) {
      return 'name may only contain lowercase letters, digits, and hyphens';
    }
    return null; // valid
  }

  /// Remove YAML frontmatter, return the markdown body.
  static String _stripFrontmatter(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines[0].trim() != '---') return content;
    var inFrontmatter = true;
    final bodyLines = <String>[];
    for (int i = 1; i < lines.length; i++) {
      if (inFrontmatter && lines[i].trim() == '---') {
        inFrontmatter = false;
        continue;
      }
      if (!inFrontmatter) {
        bodyLines.add(lines[i]);
      }
    }
    return bodyLines.join('\n').trim();
  }
}

/// Discovers and loads skills from SKILL.md files.
///
/// Progressive loading per Agent Skills spec:
/// 1. On init: scan directories, parse frontmatter, validate names
/// 2. On match: load full SKILL.md body for relevant skills
/// 3. On demand: serve reference/script files via [Skill.readFile]
class SkillLoader {
  final List<String> searchPaths;

  final List<Skill> _skills = [];

  SkillLoader({List<String>? searchPaths})
      : searchPaths = searchPaths ??
            [
              path.join(Directory.current.path, 'skills'),
              path.join(
                Platform.environment['HOME'] ?? '',
                '.config',
                'utopic',
                'skills',
              ),
            ];

  /// Scan all search paths and load skill metadata only (progressive step 1).
  List<Skill> loadAll() {
    _skills.clear();
    for (final dir in searchPaths) {
      _loadFrom(dir);
    }
    return List.unmodifiable(_skills);
  }

  void _loadFrom(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    for (final entry in dir.listSync()) {
      if (entry is Directory) {
        final skillFile = File(path.join(entry.path, 'SKILL.md'));
        if (skillFile.existsSync()) {
          final skill = _parseSkill(skillFile);
          if (skill != null) {
            _skills.add(skill);
          }
        }
      }
    }
  }

  /// Parse frontmatter only — body stays lazy for progressive loading.
  Skill? _parseSkill(File file) {
    try {
      final content = file.readAsStringSync();
      final frontmatter = _parseFrontmatter(content);
      if (frontmatter == null) return null;

      final name = frontmatter['name'] as String?;
      final description = frontmatter['description'] as String?;
      if (name == null || description == null) return null;

      // Validate name against spec
      final validationError = Skill.validateName(name);
      if (validationError != null) {
        stderr.writeln('Skill "${path.basename(file.parent.path)}": $validationError');
        return null;
      }

      // Parse optional fields
      final license = frontmatter['license'] as String?;
      final compatibility = frontmatter['compatibility'] as String?;
      final allowedTools = frontmatter['allowed-tools'] as String?;

      Map<String, String> metadata = {};
      final rawMeta = frontmatter['metadata'];
      if (rawMeta is Map) {
        metadata = rawMeta.map((k, v) => MapEntry(k.toString(), v.toString()));
      }

      return Skill._(
        name: name,
        description: description,
        filePath: file.path,
        directory: file.parent.path,
        license: license,
        compatibility: compatibility,
        metadata: metadata,
        allowedTools: allowedTools,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse YAML frontmatter from a markdown file.
  Map<String, dynamic>? _parseFrontmatter(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines[0].trim() != '---') return null;

    final yamlLines = <String>[];
    var found = false;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        found = true;
        break;
      }
      yamlLines.add(lines[i]);
    }
    if (!found || yamlLines.isEmpty) return null;

    try {
      final yaml = loadYaml(yamlLines.join('\n'));
      if (yaml is Map) {
        return Map<String, dynamic>.from(yaml);
      }
    } catch (_) {}
    return null;
  }

  /// Find skills relevant to a user message, sorted by relevance.
  /// This activates skills (loads full body) for matched results.
  List<Skill> findRelevant(String userMessage, {int maxResults = 3}) {
    final scored = _skills
        .map((s) => (skill: s, score: s.relevance(userMessage)))
        .where((s) => s.score > 0)
        .toList();
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(maxResults).map((r) {
      // Activate: load full body on match (progressive step 2)
      r.skill.body; // force lazy load
      return r.skill;
    }).toList();
  }

  /// Access skills by name.
  Skill? byName(String name) {
    final match = _skills.where((s) => s.name == name).firstOrNull;
    match?.body; // activate if found
    return match;
  }

  List<Skill> get all => List.unmodifiable(_skills);
}
