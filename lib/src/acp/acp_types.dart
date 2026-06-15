import 'dart:convert';

/// ACP (Agent Client Protocol) Types
/// Based on the Agent Client Protocol specification

typedef AcpNotificationHandler = void Function(AcpNotification);
typedef AcpRequestHandler = Future<dynamic> Function(AcpRequest);

abstract class AcpMessage {
  String get method;
  Map<String, dynamic> toJson();
}

class AcpRequest extends AcpMessage {
  @override
  final String method;
  final dynamic params;
  final dynamic id; // int or String per JSON-RPC 2.0

  AcpRequest({
    required this.method,
    this.params,
    required this.id,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      'id': id,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

class AcpResponse {
  final dynamic id; // int or String per JSON-RPC 2.0
  final dynamic result;
  final AcpError? error;

  AcpResponse({
    required this.id,
    this.result,
    this.error,
  });

  factory AcpResponse.fromJson(Map<String, dynamic> json) {
    return AcpResponse(
      id: json['id'],
      result: json['result'],
      error: json['error'] != null ? AcpError.fromJson(json['error'] as Map<String, dynamic>) : null,
    );
  }

  bool get isError => error != null;
}

class AcpError {
  final int code;
  final String message;
  final dynamic data;

  AcpError({required this.code, required this.message, this.data});

  factory AcpError.fromJson(Map<String, dynamic> json) {
    return AcpError(
      code: json['code'] as int,
      message: json['message'] as String,
      data: json['data'],
    );
  }
}

class AcpNotification {
  final String method;
  final dynamic params;

  AcpNotification({required this.method, this.params});

  factory AcpNotification.fromJson(Map<String, dynamic> json) {
    return AcpNotification(
      method: json['method'] as String,
      params: json['params'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
  }
}

/// ACP Standard Methods (matching acp_dart / agentclientprotocol.com spec)
class AcpMethods {
  static const String initialize = 'initialize';
  static const String shutdown = 'shutdown';
  static const String authenticate = 'authenticate';

  // Session lifecycle
  static const String sessionNew = 'session/new';
  static const String sessionDelete = 'session/delete';
  static const String sessionList = 'session/list';
  static const String sessionLoad = 'session/load';
  static const String sessionPrompt = 'session/prompt';
  static const String sessionCancel = 'session/cancel';
  static const String sessionSetMode = 'session/set_mode';
  static const String sessionSetConfigOption = 'session/set_config_option';
  static const String sessionSetModel = 'session/set_model';
  static const String sessionFork = 'session/fork';
  static const String sessionResume = 'session/resume';

  // Client-side methods (agent → client)
  static const String fsReadTextFile = 'fs/read_text_file';
  static const String fsWriteTextFile = 'fs/write_text_file';
  static const String sessionRequestPermission = 'session/request_permission';
  static const String sessionUpdate = 'session/update';
  static const String terminalCreate = 'terminal/create';
  static const String terminalKill = 'terminal/kill';
  static const String terminalOutput = 'terminal/output';
  static const String terminalRelease = 'terminal/release';
  static const String terminalWaitForExit = 'terminal/wait_for_exit';

  // Legacy non-standard aliases (keep for backward compat)
  static const String legacySessionCreate = 'session/create';
  static const String legacyAgentRun = 'agent/run';
  static const String legacyAgentCancel = 'agent/cancel';
  static const String legacyFsRead = 'fs/read';
  static const String legacyFsWrite = 'fs/write';
  static const String legacyFsList = 'fs/list';
  static const String legacyTerminalRun = 'terminal/run';
}

/// ACP Session Types
class AcpSession {
  final String id;
  final String agentId;
  final String cwd;
  final Map<String, dynamic> metadata;

  AcpSession({
    required this.id,
    required this.agentId,
    required this.cwd,
    this.metadata = const {},
  });

  factory AcpSession.fromJson(Map<String, dynamic> json) {
    return AcpSession(
      id: json['id'] as String,
      agentId: json['agent_id'] as String,
      cwd: json['cwd'] as String,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

}

class AcpAgentRunResult {
  final String sessionId;
  final String status;
  final dynamic output;

  AcpAgentRunResult({
    required this.sessionId,
    required this.status,
    this.output,
  });

  factory AcpAgentRunResult.fromJson(Map<String, dynamic> json) {
    return AcpAgentRunResult(
      sessionId: json['session_id'] as String,
      status: json['status'] as String,
      output: json['output'],
    );
  }
}

/// ACP Initialize Types
class AcpInitializeParams {
  final String clientName;
  final String clientVersion;
  final List<String> capabilities;

  AcpInitializeParams({
    required this.clientName,
    required this.clientVersion,
    this.capabilities = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'client_name': clientName,
      'client_version': clientVersion,
      'capabilities': capabilities,
    };
  }
}

class AcpInitializeResult {
  final String serverName;
  final String serverVersion;
  final List<String> capabilities;
  final Map<String, dynamic> agentInfo;

  AcpInitializeResult({
    required this.serverName,
    required this.serverVersion,
    required this.capabilities,
    required this.agentInfo,
  });

  factory AcpInitializeResult.fromJson(Map<String, dynamic> json) {
    return AcpInitializeResult(
      serverName: json['server_name'] as String,
      serverVersion: json['server_version'] as String,
      capabilities: List<String>.from(json['capabilities'] as List? ?? []),
      agentInfo: Map<String, dynamic>.from(json['agent_info'] as Map? ?? {}),
    );
  }
}