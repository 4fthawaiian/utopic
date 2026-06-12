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
  final int id;

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
  final int id;
  final dynamic result;
  final AcpError? error;

  AcpResponse({
    required this.id,
    this.result,
    this.error,
  });

  factory AcpResponse.fromJson(Map<String, dynamic> json) {
    return AcpResponse(
      id: json['id'] as int,
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

/// ACP Standard Methods
class AcpMethods {
  static const String initialize = 'initialize';
  static const String shutdown = 'shutdown';
  static const String sessionCreate = 'session/create';
  static const String sessionDelete = 'session/delete';
  static const String sessionList = 'session/list';
  static const String agentRun = 'agent/run';
  static const String agentCancel = 'agent/cancel';
  static const String agentPause = 'agent/pause';
  static const String agentResume = 'agent/resume';
  static const String fsRead = 'fs/read';
  static const String fsWrite = 'fs/write';
  static const String fsList = 'fs/list';
  static const String fsGlob = 'fs/glob';
  static const String fsGrep = 'fs/grep';
  static const String terminalCreate = 'terminal/create';
  static const String terminalWrite = 'terminal/write';
  static const String terminalKill = 'terminal/kill';
  static const String terminalWait = 'terminal/wait';
  static const String terminalResize = 'terminal/resize';
  static const String terminalRun = 'terminal/run';
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