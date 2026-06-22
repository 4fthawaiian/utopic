import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as path;

/// Which AI provider to use by default.
enum AiProvider { zen, openrouter }

class AppConfig {
  final String? opencodeApiKey;
  final String defaultModel;
  final String zenEndpoint;

  final String? openrouterApiKey;
  final String openrouterEndpoint;
  final String defaultOpenrouterModel;
  final AiProvider provider;

  final AcpConfig acp;
  final String? systemPrompt;
  final String? promptFile;
  final int maxIterations;

  AppConfig({
    this.opencodeApiKey,
    required this.defaultModel,
    required this.zenEndpoint,
    this.openrouterApiKey,
    this.openrouterEndpoint = 'https://openrouter.ai/api/v1',
    this.defaultOpenrouterModel = 'openai/gpt-4o',
    this.provider = AiProvider.zen,
    required this.acp,
    this.systemPrompt,
    this.promptFile,
    this.maxIterations = 10,
  });

  factory AppConfig.fromYaml(Map<dynamic, dynamic> yaml) {
    return AppConfig(
      opencodeApiKey: yaml['opencode_api_key'] as String?,
      defaultModel: yaml['default_model'] as String? ?? 'deepseek-v4-flash-free',
      zenEndpoint: yaml['zen_endpoint'] as String? ?? 'https://opencode.ai/zen',
      openrouterApiKey: yaml['openrouter_api_key'] as String?,
      openrouterEndpoint: yaml['openrouter_endpoint'] as String? ??
          'https://openrouter.ai/api/v1',
      defaultOpenrouterModel: yaml['default_openrouter_model'] as String? ??
          'openai/gpt-4o',
      provider: _parseProvider(yaml['provider'] as String?),
      systemPrompt: yaml['system_prompt'] as String?,
      acp: AcpConfig.fromYaml(Map<dynamic, dynamic>.from(yaml['acp'] as Map? ?? {})),
      maxIterations: yaml['max_iterations'] as int? ?? 10,
    );
  }

  static AiProvider _parseProvider(String? value) {
    if (value == null) return AiProvider.zen;
    switch (value.toLowerCase()) {
      case 'openrouter':
        return AiProvider.openrouter;
      default:
        return AiProvider.zen;
    }
  }

  factory AppConfig.load({String? promptFile, String? configPath, AiProvider? provider}) {
    final configPaths = <File>[
      if (configPath != null && configPath.isNotEmpty)
        File(configPath),
      if (Platform.environment['UTOPIC_CONFIG']?.isNotEmpty == true)
        File(Platform.environment['UTOPIC_CONFIG']!),
      File(path.join(Directory.current.path, 'config.yaml')),
      File(path.join(Platform.environment['HOME'] ?? '', '.config', 'utopic', 'config.yaml')),
      File(path.join(Platform.environment['HOME'] ?? '', '.config.yaml')),
    ];

    // Start with defaults (env vars) and merge YAML configs on top,
    // so that values from later config files fill in what's missing
    // from earlier ones.  This means ~/.config/utopic/config.yaml can
    // supply API keys or other settings that aren't in ./config.yaml.
    String? opencodeApiKey;
    String? defaultModel;
    String? zenEndpoint;
    String? openrouterApiKey;
    String? openrouterEndpoint;
    String? defaultOpenrouterModel;
    AiProvider? cfgProvider;
    String? systemPrompt;
    AcpConfig? acpCfg;
    int? maxIterations;

    for (final configFile in configPaths) {
      if (!configFile.existsSync()) continue;
      try {
        final content = configFile.readAsStringSync();
        final yaml = loadYaml(content);
        if (yaml is! Map) continue;
        final cfg = AppConfig.fromYaml(Map<dynamic, dynamic>.from(yaml));
        // Merge: only override if the YAML provided a non-null value
        opencodeApiKey ??= cfg.opencodeApiKey;
        defaultModel ??= cfg.defaultModel;
        zenEndpoint ??= cfg.zenEndpoint;
        openrouterApiKey ??= cfg.openrouterApiKey;
        openrouterEndpoint ??= cfg.openrouterEndpoint;
        defaultOpenrouterModel ??= cfg.defaultOpenrouterModel;
        cfgProvider ??= cfg.provider;
        systemPrompt ??= cfg.systemPrompt;
        acpCfg ??= cfg.acp;
        maxIterations ??= cfg.maxIterations;
      } catch (_) {
        // Skip malformed config files
        continue;
      }
    }

    // Final fallback: env vars for API keys (even if a config file was
    // found, if it didn't set the key, use the env var)
    opencodeApiKey ??= Platform.environment['OPENCODE_API_KEY'];
    openrouterApiKey ??= Platform.environment['OPENROUTER_API_KEY'];

    return AppConfig(
      opencodeApiKey: opencodeApiKey,
      defaultModel: defaultModel ?? 'deepseek-v4-flash-free',
      zenEndpoint: zenEndpoint ?? 'https://opencode.ai/zen',
      openrouterApiKey: openrouterApiKey,
      openrouterEndpoint: openrouterEndpoint ?? 'https://openrouter.ai/api/v1',
      defaultOpenrouterModel: defaultOpenrouterModel ?? 'openai/gpt-4o',
      provider: provider ?? cfgProvider ?? AiProvider.zen,
      systemPrompt: systemPrompt,
      acp: acpCfg ?? AcpConfig.defaultConfig(),
      promptFile: promptFile,
      maxIterations: maxIterations ?? 10,
    );
  }

  factory AppConfig.defaultConfig({String? promptFile, AiProvider? provider}) {
    return AppConfig(
      opencodeApiKey: Platform.environment['OPENCODE_API_KEY'],
      defaultModel: 'deepseek-v4-flash-free',
      zenEndpoint: 'https://opencode.ai/zen',
      openrouterApiKey: Platform.environment['OPENROUTER_API_KEY'],
      openrouterEndpoint: 'https://openrouter.ai/api/v1',
      defaultOpenrouterModel: 'openai/gpt-4o',
      provider: provider ?? AiProvider.zen,
      acp: AcpConfig.defaultConfig(),
      promptFile: promptFile,
    );
  }
}

class AcpConfig {
  final String socketPath;
  final int port;
  final String host;
  final List<AcpClientConfig> clients;

  AcpConfig({
    required this.socketPath,
    required this.port,
    required this.host,
    this.clients = const [],
  });

  factory AcpConfig.fromYaml(Map<dynamic, dynamic> yaml) {
    final clientsRaw = yaml['clients'] as List? ?? [];
    final clients = clientsRaw.map((c) {
      if (c is Map) {
        return AcpClientConfig(
          host: c['host'] as String? ?? '127.0.0.1',
          port: c['port'] as int? ?? 8080,
        );
      }
      return AcpClientConfig();
    }).toList();

    return AcpConfig(
      socketPath: yaml['socket_path'] as String? ?? '',
      port: yaml['port'] as int? ?? 8080,
      host: yaml['host'] as String? ?? '127.0.0.1',
      clients: clients,
    );
  }

  factory AcpConfig.defaultConfig() {
    return AcpConfig(
      socketPath: '',
      port: 8080,
      host: '127.0.0.1',
    );
  }
}

class AcpClientConfig {
  final String host;
  final int port;

  AcpClientConfig({this.host = '127.0.0.1', this.port = 8080});
}