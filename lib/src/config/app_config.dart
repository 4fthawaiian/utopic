import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as path;

class AppConfig {
  final String? opencodeApiKey;
  final String defaultModel;
  final String zenEndpoint;
  final AcpConfig acp;
  final String? systemPrompt;
  final String? promptFile;

  AppConfig({
    this.opencodeApiKey,
    required this.defaultModel,
    required this.zenEndpoint,
    required this.acp,
    this.systemPrompt,
    this.promptFile,
  });

  factory AppConfig.fromYaml(Map<dynamic, dynamic> yaml) {
    return AppConfig(
      opencodeApiKey: yaml['opencode_api_key'] as String?,
      defaultModel: yaml['default_model'] as String? ?? 'deepseek-v4-flash-free',
      zenEndpoint: yaml['zen_endpoint'] as String? ?? 'https://opencode.ai/zen',
      systemPrompt: yaml['system_prompt'] as String?,
      acp: AcpConfig.fromYaml(Map<dynamic, dynamic>.from(yaml['acp'] as Map? ?? {})),
    );
  }

  factory AppConfig.load({String? promptFile, String? configPath}) {
    final configPaths = <File>[
      if (configPath != null && configPath.isNotEmpty)
        File(configPath),
      if (Platform.environment['UTOPIC_CONFIG']?.isNotEmpty == true)
        File(Platform.environment['UTOPIC_CONFIG']!),
      File(path.join(Directory.current.path, 'utopic.yaml')),
      File(path.join(Platform.environment['HOME'] ?? '', '.config', 'utopic', 'config.yaml')),
      File(path.join(Platform.environment['HOME'] ?? '', '.utopic.yaml')),
    ];

    for (final configFile in configPaths) {
      if (configFile.existsSync()) {
        final content = configFile.readAsStringSync();
        final yaml = loadYaml(content);
        if (yaml is Map) {
          final cfg = AppConfig.fromYaml(Map<dynamic, dynamic>.from(yaml));
          // Return a new instance with the CLI promptFile override
          return AppConfig(
            opencodeApiKey: cfg.opencodeApiKey,
            defaultModel: cfg.defaultModel,
            zenEndpoint: cfg.zenEndpoint,
            systemPrompt: cfg.systemPrompt,
            acp: cfg.acp,
            promptFile: promptFile ?? cfg.promptFile,
          );
        }
      }
    }

    return AppConfig.defaultConfig(promptFile: promptFile);
  }

  factory AppConfig.defaultConfig({String? promptFile}) {
    return AppConfig(
      opencodeApiKey: Platform.environment['OPENCODE_API_KEY'],
      defaultModel: 'deepseek-v4-flash-free',
      zenEndpoint: 'https://opencode.ai/zen',
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