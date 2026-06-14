import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:acp_dart/acp_dart.dart';

/// ACP model option — wraps SessionConfigSelectOption for the model selector.
class AcpModelOption {
  final String id;
  final String label;
  final String? description;

  AcpModelOption({required this.id, required this.label, this.description});

  Map<String, dynamic> toJson() => {
        'value': id,
        'name': label,
        if (description != null) 'description': description,
      };
}

/// Collects text chunks from agent_message_chunk notifications.
class _ChunkCollector {
  final List<String> chunks = [];
  bool _active = false;

  void start() => _active = true;
  void stop() => _active = false;
  bool get active => _active;

  void add(String text) {
    if (_active) chunks.add(text);
  }

  String join() => chunks.join();
  void clear() => chunks.clear();
}

/// ACP connection using the official acp_dart library.
class AcpDartConnection {
  ClientSideConnection? _connection;
  AcpStream? _stream;
  Process? _process;
  Socket? _tcpSocket;
  String? _sessionId;
  String? _currentModelId;
  final List<SessionConfigOption> _configOptions = [];
  final _chunks = _ChunkCollector();

  /// Server info from initialization.
  InitializeResponse? serverInfo;

  bool get isConnected => _connection != null;

  /// Available models extracted from session config options.
  List<AcpModelOption> get availableModels {
    // First try the model config option
    for (final opt in _configOptions) {
      if (opt.id == 'model' || opt.id == 'model_id') {
        if (opt.options is UngroupedSessionConfigSelectOptions) {
          return (opt.options as UngroupedSessionConfigSelectOptions)
              .options
              .map((o) => AcpModelOption(
                    id: o.value.toString(),
                    label: o.name,
                    description: o.description,
                  ))
              .toList();
        }
      }
    }
    return [];
  }

  String? get currentModelId => _currentModelId;

  /// The remote server name from the initialize response.
  String get serverName => serverInfo?.agentInfo?.name ?? 'acp';

  /// Connect to a local CLI subprocess as the ACP agent.
  Future<void> connectToCli(String command, List<String> args) async {
    stderr.writeln('ACP: spawning $command ${args.join(' ')}');
    await disconnect();

    _process = await Process.start(command, args,
        mode: ProcessStartMode.normal);
    stderr.writeln('ACP: spawned pid=${_process!.pid}');

    // Pipe stderr from the child process to our stderr for debugging
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('ACP(child): $line');
    });

    _stream = ndJsonStream(
      _process!.stdout,
      _process!.stdin,
      onParseError: (line, error) {
        stderr.writeln('ACP parse error: $error\n  line: $line');
      },
    );

    stderr.writeln('ACP: stream created, initializing...');
    await _createConnection();
    stderr.writeln('ACP: connection ready');
  }

  /// Connect to a remote ACP agent via TCP.
  Future<void> connectToTcp(String host, int port) async {
    await disconnect();

    final socket = await Socket.connect(host, port)
        .timeout(const Duration(seconds: 5));
    _tcpSocket = socket;

    // Build an AcpStream from the TCP socket
    final readable = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .transform(
          StreamTransformer<String, Map<String, dynamic>>.fromHandlers(
            handleData: (line, sink) {
              final trimmed = line.trim();
              if (trimmed.isEmpty) return;
              try {
                final decoded = jsonDecode(trimmed);
                if (decoded is Map<String, dynamic>) {
                  sink.add(decoded);
                }
              } catch (e) {
                stderr.writeln('ACP TCP parse error: $e\n  line: $line');
              }
            },
          ),
        );

    final writableController = StreamController<Map<String, dynamic>>();
    writableController.stream.listen(
      (message) {
        final jsonString = '${jsonEncode(message)}\n';
        socket.write(jsonString);
      },
      onDone: () => socket.destroy(),
    );

    _stream = AcpStream(
      readable: readable,
      writable: writableController.sink,
    );

    await _createConnection();
  }

  /// Disconnect and clean up.
  Future<void> disconnect() async {
    _sessionId = null;
    _configOptions.clear();
    _chunks.clear();
    _connection = null;
    _stream = null;

    if (_tcpSocket != null) {
      try { _tcpSocket!.destroy(); } catch (_) {}
      _tcpSocket = null;
    }

    if (_process != null) {
      try { _process?.stdin.close(); } catch (_) {}
      try { _process?.kill(ProcessSignal.sigkill); } catch (_) {}
      _process = null;
    }
  }

  /// Create the ClientSideConnection and initialize.
  Future<void> _createConnection() async {
    if (_stream == null) throw StateError('No stream');

    _connection = ClientSideConnection(
      (conn) => _AcpClientHandler(this),
      _stream!,
    );

    stderr.writeln('ACP: sending initialize...');
    try {
      serverInfo = await _connection!.initialize(InitializeRequest(
        protocolVersion: 1,
        clientInfo: Implementation(
          name: 'utopic',
          version: '1.0.0',
        ),
        clientCapabilities: ClientCapabilities(
          fs: FileSystemCapability(),
          terminal: true,
        ),
      ));
      stderr.writeln('ACP: initialized, server=${serverInfo?.agentInfo?.name ?? '?'}');
    } catch (e) {
      stderr.writeln('ACP initialize failed: $e');
      rethrow;
    }
  }

  /// Create a new session.
  Future<void> createSession() async {
    if (_connection == null) throw StateError('Not connected');
    if (_sessionId != null) return;

    stderr.writeln('ACP: creating session...');
    try {
      final response = await _connection!.newSession(NewSessionRequest(
        cwd: Directory.current.path,
        mcpServers: [],
      ));

      _sessionId = response.sessionId;
      stderr.writeln('ACP: session created id=$_sessionId');

      if (response.configOptions != null) {
        _configOptions
          ..clear()
          ..addAll(response.configOptions!);
        stderr.writeln('ACP: got ${response.configOptions!.length} config options');
        for (final opt in response.configOptions!) {
          stderr.writeln('ACP:   config: ${opt.id} = ${opt.name} (current=${opt.currentValue})');
        }
      } else {
        stderr.writeln('ACP: no config options in response');
      }
    } catch (e) {
      stderr.writeln('ACP newSession failed: $e');
      rethrow;
    }
  }

  /// Send a prompt and collect the response text.
  Future<Map<String, dynamic>> complete(String prompt) async {
    if (_connection == null) throw StateError('Not connected');
    if (_sessionId == null) await createSession();

    _chunks.clear();
    _chunks.start();

    try {
      final response = await _connection!.prompt(PromptRequest(
        sessionId: _sessionId!,
        prompt: [TextContentBlock(text: prompt)],
      ));

      _chunks.stop();
      final text = _chunks.join();

      int inputTokens = 0, outputTokens = 0;
      if (response.usage != null) {
        inputTokens = response.usage!.inputTokens;
        outputTokens = response.usage!.outputTokens;
      }

      return {
        'content': text,
        'model': _currentModelId ?? 'acp',
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };
    } catch (e) {
      _chunks.stop();
      rethrow;
    }
  }

  /// Set the model for the current session.
  Future<void> setModel(String modelId) async {
    _currentModelId = modelId;
    if (_connection != null && _sessionId != null) {
      try {
        await _connection!.setSessionConfigOption(
          SetSessionConfigOptionRequest(
            sessionId: _sessionId!,
            configId: 'model',
            value: modelId,
          ),
        );
      } catch (e) {
        stderr.writeln('ACP set model failed: $e');
      }
    }
  }
}

/// Client-side handler for incoming agent requests.
class _AcpClientHandler implements Client {
  final AcpDartConnection _parent;

  _AcpClientHandler(this._parent);

  @override
  Future<RequestPermissionResponse> requestPermission(
      RequestPermissionRequest params) async {
    // Auto-approve tool permissions
    return RequestPermissionResponse(
      outcome: SelectedOutcome(optionId: 'approve'),
    );
  }

  @override
  Future<void> sessionUpdate(SessionNotification params) async {
    if (params.update is ConfigOptionUpdate) {
      final update = params.update as ConfigOptionUpdate;
      _parent._configOptions
        ..clear()
        ..addAll(update.configOptions);
      return;
    }

    if (params.update is AgentMessageChunkSessionUpdate) {
      final update = params.update as AgentMessageChunkSessionUpdate;
      if (update.content is TextContentBlock && _parent._chunks.active) {
        _parent._chunks.add((update.content as TextContentBlock).text);
      }
      return;
    }
  }

  @override
  Future<ReadTextFileResponse>? readTextFile(ReadTextFileRequest params) async {
    try {
      final file = File(params.path);
      final content = await file.readAsString();
      return ReadTextFileResponse(content: content);
    } catch (e) {
      throw RequestError.resourceNotFound(params.path);
    }
  }

  @override
  Future<WriteTextFileResponse>? writeTextFile(
      WriteTextFileRequest params) async {
    try {
      final file = File(params.path);
      await file.writeAsString(params.content);
      return WriteTextFileResponse();
    } catch (e) {
      throw RequestError.internalError(e.toString());
    }
  }

  @override
  Future<CreateTerminalResponse>? createTerminal(
      CreateTerminalRequest params) async {
    throw RequestError.methodNotFound('terminal/create');
  }

  @override
  Future<TerminalOutputResponse>? terminalOutput(
      TerminalOutputRequest params) async {
    throw RequestError.methodNotFound('terminal/output');
  }

  @override
  Future<ReleaseTerminalResponse?>? releaseTerminal(
      ReleaseTerminalRequest params) async {
    throw RequestError.methodNotFound('terminal/release');
  }

  @override
  Future<WaitForTerminalExitResponse>? waitForTerminalExit(
      WaitForTerminalExitRequest params) async {
    throw RequestError.methodNotFound('terminal/wait_for_exit');
  }

  @override
  Future<KillTerminalCommandResponse?>? killTerminal(
      KillTerminalCommandRequest params) async {
    throw RequestError.methodNotFound('terminal/kill');
  }

  @override
  Future<Map<String, dynamic>>? extMethod(
      String method, Map<String, dynamic> params) async {
    throw RequestError.methodNotFound(method);
  }

  @override
  Future<void>? extNotification(
      String method, Map<String, dynamic> params) async {
    return;
  }
}
