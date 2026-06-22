/// OpenCode Zen Models + OpenRouter Models
///
/// Initialized with sensible defaults. Call [fetchFromApi] to
/// refresh the list from the OpenCode API, or [fetchFromOpenrouter]
/// for OpenRouter models. If the API is unreachable, the default
/// lists serve as fallback.
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

/// Models Catalog — holds both Zen API and OpenRouter model lists.
class ZenModels {
  /// Sensible defaults — covers the most useful Zen models.
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
    ZenModel(id: 'gpt-5.5-pro', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'gpt-5.4', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'gpt-5.4-mini', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'gpt-5.4-nano', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'gpt-5-nano', provider: 'openai', contextLimit: 128000),

    // Gemini
    ZenModel(id: 'gemini-3.5-flash', provider: 'google', contextLimit: 1000000),
    ZenModel(id: 'gemini-3.1-pro', provider: 'google', contextLimit: 1000000),

    // DeepSeek
    ZenModel(id: 'deepseek-v4-flash', provider: 'deepseek', contextLimit: 128000),
    ZenModel(id: 'deepseek-v4-pro', provider: 'deepseek', contextLimit: 128000),

    // Others
    ZenModel(id: 'grok-build-0.1', provider: 'xai', contextLimit: 128000),
    ZenModel(id: 'qwen3.6-plus', provider: 'qwen', contextLimit: 128000),
    ZenModel(id: 'kimi-k2.5', provider: 'moonshot', contextLimit: 128000),
  ];

  /// Default OpenRouter models (popular ones).
  /// Full list is fetched from the API on startup.
  static const List<ZenModel> _openrouterDefaults = [
    ZenModel(id: 'openai/gpt-4o', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'openai/gpt-4o-mini', provider: 'openai', contextLimit: 128000),
    ZenModel(id: 'openai/o3-mini', provider: 'openai', contextLimit: 200000),
    ZenModel(id: 'openai/o1', provider: 'openai', contextLimit: 200000),
    ZenModel(id: 'anthropic/claude-sonnet-4', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'anthropic/claude-3.5-sonnet', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'anthropic/claude-3-haiku', provider: 'anthropic', contextLimit: 200000),
    ZenModel(id: 'google/gemini-2.0-flash-001', provider: 'google', contextLimit: 1000000),
    ZenModel(id: 'google/gemini-2.0-pro-001', provider: 'google', contextLimit: 1000000),
    ZenModel(id: 'deepseek/deepseek-r1', provider: 'deepseek', contextLimit: 128000),
    ZenModel(id: 'deepseek/deepseek-v3', provider: 'deepseek', contextLimit: 128000),
    ZenModel(id: 'meta-llama/llama-3.3-70b-instruct', provider: 'meta', contextLimit: 128000),
    ZenModel(id: 'mistralai/mistral-large-2411', provider: 'mistral', contextLimit: 128000),
    ZenModel(id: 'qwen/qwen2.5-72b-instruct', provider: 'qwen', contextLimit: 32768),
    ZenModel(id: 'cohere/command-r7b-12-2024', provider: 'cohere', contextLimit: 128000),
    ZenModel(id: 'x-ai/grok-2-1212', provider: 'xai', contextLimit: 131072),
  ];

  // ─── Zen API model list ──────────────────────────────────────────────
  static List<ZenModel> _models = List.from(_defaults);
  static Map<String, ZenModel> _byId = {for (final m in _defaults) m.id: m};

  /// All currently known Zen API models.
  static List<ZenModel> get all => List.unmodifiable(_models);

  /// Get model by ID (e.g. `deepseek-v4-flash-free`).
  static ZenModel? get(String id) => _byId[id];

  // ─── OpenRouter model list ───────────────────────────────────────────
  static List<ZenModel> _openrouterModels = List.from(_openrouterDefaults);
  static Map<String, ZenModel> _openrouterById =
      {for (final m in _openrouterDefaults) m.id: m};

  /// All currently known OpenRouter models.
  static List<ZenModel> get openrouterAll =>
      List.unmodifiable(_openrouterModels);

  /// Get an OpenRouter model by ID (e.g. `openai/gpt-4o`).
  static ZenModel? openrouterGet(String id) => _openrouterById[id];

  /// Look up the context window limit for a model ID.
  /// Checks both Zen and OpenRouter lists, then falls back to
  /// sensible defaults based on model family, then to [defaultLimit].
  static int contextLimitFor(String modelId, {int defaultLimit = 128000}) {
    // Check Zen models first
    final model = _byId[modelId];
    if (model != null) return model.contextLimit;
    // Then OpenRouter models
    final orModel = _openrouterById[modelId];
    if (orModel != null) return orModel.contextLimit;
    // Family-based fallbacks
    final lower = modelId.toLowerCase();
    if (lower.contains('claude') || lower.contains('fable')) return 200000;
    if (lower.contains('gemini')) return 1000000;
    if (lower.contains('gpt') || lower.contains('o1') || lower.contains('o3')) {
      return 128000;
    }
    if (lower.contains('deepseek')) return 128000;
    if (lower.contains('llama')) return 128000;
    if (lower.contains('mistral')) return 128000;
    return defaultLimit;
  }

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
    if (lower.contains('meta') || lower.contains('llama')) return 'meta';
    if (lower.contains('mistral')) return 'mistral';
    if (lower.contains('cohere') || lower.contains('command')) return 'cohere';
    return 'other';
  }

  /// Merge models from the OpenCode Zen API.
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

  /// Fetch models from the OpenRouter API and merge into the [openrouterAll] list.
  static void fetchFromOpenrouter(String endpoint, {String? apiKey}) {
    // We can't use http directly here since this is a static model catalog.
    // The actual HTTP call is done by OpenRouterAiService.fetchModels().
    // This method is a placeholder for merging results from that call.
  }

  /// Merge OpenRouter models from the API response into the catalog.
  static void mergeOpenrouterModels(List<Map<String, dynamic>> apiModels) {
    final updated = <ZenModel>[];
    final seenIds = <String>{};

    for (final raw in apiModels) {
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty) continue;
      seenIds.add(id);

      final existing = _openrouterById[id];
      if (existing != null) {
        updated.add(existing);
      } else {
        final ownedBy = raw['owned_by'] as String? ?? '';
        updated.add(ZenModel(
          id: id,
          provider: _inferProvider(ownedBy.isNotEmpty ? ownedBy : id),
        ));
      }
    }

    // Keep defaults that the API didn't enumerate
    for (final m in _openrouterDefaults) {
      if (!seenIds.contains(m.id)) {
        updated.add(m);
      }
    }

    _openrouterModels = updated;
    _openrouterById = {for (final m in _openrouterModels) m.id: m};
  }
}
