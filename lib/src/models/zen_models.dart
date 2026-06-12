/// OpenCode Zen Models
///
/// Initialized with sensible defaults. Call [fetchFromApi] to
/// refresh the list from the OpenCode API. If the API is
/// unreachable, the default list serves as fallback.
library;

class ZenModel {
  final String id;
  final String provider;
  final bool isFree;
  final bool supportsStreaming;
  final int contextLimit;

  const ZenModel({
    required this.id,
    required this.provider,
    this.isFree = false,
    this.supportsStreaming = true,
    this.contextLimit = 128000,
  });

  String get displayName => id;
}

/// Zen Models Catalog
class ZenModels {
  /// Sensible defaults — covers the most useful models.
  /// Updated from the API on startup.
  static const List<ZenModel> _defaults = [
    // Free models
    ZenModel(id: 'deepseek-v4-flash-free', provider: 'deepseek', isFree: true),
    ZenModel(id: 'mimo-v2.5-free', provider: 'mimo', isFree: true),
    ZenModel(id: 'qwen3.6-plus-free', provider: 'qwen', isFree: true),
    ZenModel(id: 'nemotron-3-ultra-free', provider: 'nvidia', isFree: true),
    ZenModel(id: 'north-mini-code-free', provider: 'north', isFree: true),

    // Claude
    ZenModel(id: 'claude-sonnet-4', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'claude-sonnet-4-5', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'claude-sonnet-4-6', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'claude-haiku-4-5', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'claude-opus-4-5', provider: 'anthropic', contextLimit: 200000),

    // GPT
    ZenModel(id: 'gpt-5.5-pro', provider: 'openai'),
    ZenModel(id: 'gpt-5.4', provider: 'openai'),
    ZenModel(id: 'gpt-5.4-mini', provider: 'openai'),
    ZenModel(id: 'gpt-5.4-nano', provider: 'openai'),
    ZenModel(id: 'gpt-5-nano', provider: 'openai'),

    // Gemini
    ZenModel(id: 'gemini-3.5-flash', provider: 'google'),
    ZenModel(id: 'gemini-3.1-pro', provider: 'google'),

    // DeepSeek
    ZenModel(id: 'deepseek-v4-flash', provider: 'deepseek'),
    ZenModel(id: 'deepseek-v4-pro', provider: 'deepseek'),

    // Others
    ZenModel(id: 'grok-build-0.1', provider: 'xai'),
    ZenModel(id: 'qwen3.6-plus', provider: 'qwen'),
    ZenModel(id: 'kimi-k2.5', provider: 'moonshot'),
  ];

  static List<ZenModel> _models = List.from(_defaults);
  static Map<String, ZenModel> _byId = {for (final m in _defaults) m.id: m};

  /// All currently known models.
  static List<ZenModel> get all => List.unmodifiable(_models);

  /// Get model by ID (e.g. `deepseek-v4-flash-free`).
  static ZenModel? get(String id) => _byId[id];

  /// Inherit provider from the model ID string.
  static String _inferProvider(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('claude') || lower.contains('fable')) return 'anthropic';
    if (lower.contains('gpt') || lower.contains('o1') || lower.contains('o3')) return 'openai';
    if (lower.contains('gemini')) return 'google';
    if (lower.contains('deepseek')) return 'deepseek';
    if (lower.contains('qwen')) return 'qwen';
    if (lower.contains('kimi')) return 'moonshot';
    if (lower.contains('grok')) return 'xai';
    if (lower.contains('nemotron')) return 'nvidia';
    if (lower.contains('mimo')) return 'mimo';
    if (lower.contains('minimax')) return 'minimax';
    if (lower.contains('north')) return 'north';
    if (lower.contains('glm')) return 'zhipu';
    if (lower.contains('big-pickle')) return 'opencode';
    return 'other';
  }

  /// Merge models from the OpenCode API.
  static void fetchFromApi(List<Map<String, dynamic>> apiModels) {
    final updated = <ZenModel>[];
    final seenIds = <String>{};

    for (final raw in apiModels) {
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty) continue;
      seenIds.add(id);

      final existing = _byId[id];
      if (existing != null) {
        updated.add(existing);
      } else {
        final ownedBy = raw['owned_by'] as String? ?? '';
        updated.add(ZenModel(
          id: id,
          provider: _inferProvider(ownedBy.isNotEmpty ? ownedBy : id),
          isFree: id.contains('free'),
        ));
      }
    }

    // Keep defaults that the API didn't enumerate
    for (final m in _defaults) {
      if (!seenIds.contains(m.id)) {
        updated.add(m);
      }
    }

    _models = updated;
    _byId = {for (final m in _models) m.id: m};
  }
}
