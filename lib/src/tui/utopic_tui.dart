import 'dart:io';
import 'package:utopia_tui/utopia_tui.dart';
import '../services/agent_service.dart';
import '../config/app_config.dart';
import '../models/conversation.dart';
import '../models/zen_models.dart';
import '../services/ai_service.dart';

/// Utopic TUI Agent Application
///
/// Simple non-modal interface:
///   Type your message, press Enter to send
///   Alt+Enter to insert a newline (shows as ↵)
///   /command for actions
///   Arrow keys / PgUp/PgDn to scroll
///   Ctrl+D to quit  /  Ctrl+C to cancel
class UtopicTuiApp extends TuiApp {
  final AppConfig config;
  late final AgentService _agent;
  final _scroll = TuiScrollView();
  String _input = '';
  int _cursor = 0;
  String _status = 'Starting...';
  bool _quitting = false;
  bool _selectingModel = false;
  bool _isProcessing = false;
  DateTime? _lastEscapeTime;
  bool _phobeMode = false;
  int _selIndex = 0;
  int _spinnerFrame = 0;
  final String? _loadSessionId;

  /// Models available for selection — ACP remote models if connected,
  /// otherwise the built-in Zen models.
  List<Map<String, dynamic>> get _modelList {
    if (_agent.isUsingAcp && _agent.ai is AcpAiService) {
      final acp = _agent.ai as AcpAiService;
      final acpModels = acp.availableModels;
      if (acpModels.isNotEmpty) return acpModels;
    }
    // Fall back to Zen models (or empty list).
    return ZenModels.all.map((m) => {'value': m.id, 'name': m.id}).toList();
  }

  /// Tick 6×/s for smooth animation of the thinking spinner.
  @override
  Duration? get tickInterval => const Duration(milliseconds: 166);

  UtopicTuiApp({required this.config, this._phobeMode = false, this._loadSessionId});

  @override
  void init(TuiContext context) {
    _agent = AgentService(config: config);
    _agent.phobeMode = _phobeMode;
    
    // initialize() is async; chain the session load after it.
    try {
      _agent.initialize().then((_) {
        // Load a specific session if --load was given
        final loadId = _loadSessionId;
        if (loadId != null) {
          _agent.loadSession(loadId).then((conv) {
            if (conv != null) {
              _status = 'Loaded: ${conv.title}  ·  ${_agent.ai.currentModel}';
            } else {
              _status = 'Session not found: $loadId';
            }
            _refreshChat(context);
          });
        }
        _status = 'Ready  ·  ${_agent.ai.currentModel}  ·  /help';
        _refreshChat(context);
      }).catchError((e) {
        _status = 'Init error: $e';
      });
    } catch (e) {
      _status = 'Init error: $e';
    }

    _agent.conversationsStream.listen((_) => _refreshChat(context));
    _agent.activeConversationStream.listen((_) => _refreshChat(context));
  }

  void _refreshChat(TuiContext context) {
    final conv = _agent.activeConversation;
    if (conv == null) return;
    _scroll.setLines(_convToLines(conv));
    _scrollToBottom(context);
  }

  void _scrollToBottom(TuiContext context) {
    _scroll.scrollBottom(context.height - 4, context.width - 4);
  }

  // Pride colors (rainbow flag) for cycling message headers
  static const _prideColors = [196, 208, 226, 46, 39, 129];
  int _msgCount = 0;

  int _nextColor() {
    _msgCount++;
    if (_phobeMode) return 244; // boring gray
    return _prideColors[_msgCount % _prideColors.length];
  }

  // Escape codes for inline color — utopia_tui doesn't support inline styles
  // so we use ANSI directly in the scroll content.
  static const _reset = '\x1b[0m';

  String _header(String label, int color) {
    return '\x1b[38;5;${color}m── $label ──$_reset';
  }

  List<String> _convToLines(Conversation conv) {
    final out = <String>[];
    for (final msg in conv.messages) {
      if (msg.role == 'system') continue;
      out.add('');

      if (msg.role == 'user') {
        out.add(_header('You', _nextColor()));
      } else if (msg.role == 'assistant') {
        if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          out.add(_header('Tool calls', _nextColor()));
          for (final tc in msg.toolCalls!) {
            out.add('  🔧 ${tc['name']}(${tc['arguments']})');
          }
          continue;
        }
        out.add(_header('Utopic', _nextColor()));
      } else if (msg.role == 'tool') {
        out.add(_header('Result', _nextColor()));
      }
      out.add('');
      for (final line in msg.content.split('\n')) {
        out.add(line);
      }
    }
    return out;
  }

  void _submit(TuiContext context) {
    final text = _input.trim();
    if (text.isEmpty) return;

    _input = '';
    _cursor = 0;

    if (text == '/quit' || text == ':q') {
      _quitting = true;
      // Restore terminal before exit
      stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l');
      printSessionSummary();
      exit(0);
    }

    if (text.startsWith('/')) {
      _runCommand(text.substring(1), context);
      return;
    }

    _status = 'Thinking...';
    _isProcessing = true;
    _agent.sendMessage(text).then((_) {
      _status = 'Ready  ·  ${_agent.ai.currentModel}';
      _isProcessing = false;
      _refreshChat(context);
    }).catchError((e) {
      _status = 'Error: $e';
      _isProcessing = false;
      _refreshChat(context);
    });
  }

  void _runCommand(String cmd, TuiContext context) {
    final parts = cmd.trim().split(RegExp(r'\s+'));
    final c = parts[0].toLowerCase();

    switch (c) {
      case 'help':
        final lines = <String>[
          '',
          ' ═══════════════════════════════════════',
          '              UTOPIC HELP               ',
          ' ═══════════════════════════════════════',
          '',
          '  Type anything and press Enter to chat.',
          '  Type /command for actions.',
          '',
          '  SCROLLING:',
          '    ↑/↓          Line up/down',
          '    PgUp/PgDn    Page up/down',
          '    Home/End      Top/bottom',
          '',
          '  COMMANDS:',
          '    /help         This help',
          '    /new          New conversation',
          '    /model        Interactive model selector',
          '    /model <id>   Switch model by ID',
          '    /models       List models',
          '    /prompt       Show current prompt override',
          '    /prompt <t>   Set per-conversation system prompt',
          '    /acp          Toggle ACP server (accept connections)',
          '    /acp-connect <host> <port>  Connect to remote ACP server as provider',
          '    /acp-connect cli:<cmd>      Spawn local CLI as ACP provider',
          '    /acp-disconnect  Disconnect from remote ACP provider',
          '    /save         Save current conversation',
          '    /load <id>    Load a saved conversation',
          '    /list         List conversations',
          '    /switch <n>   Switch conversation',
          '    /phobe        Toggle phobe mode (remove pride theming)',
          '    /quit         Exit',
          '',
          '  MODELS:',
          for (final m in _modelList)
            '    ${_agent.ai.currentModel == m['value'] ? '◀' : ' '} ${m['name']}',
          '',
          if (_agent.isUsingAcp)
            '  ACP provider: ✅ ${_agent.ai.currentModel}'
          else if (_agent.isAcpRunning)
            '  ACP server: ✅ ${config.acp.host}:${config.acp.port}'
          else
            '  ACP: ❌ stopped  (/acp to start server, /acp-connect for provider)',
          '',
        ];
        _scroll.setLines(lines);
        _scroll.scrollTop();
        _status = 'Help';
        return;

      case 'new':
        _agent.createNewConversation();
        _status = 'New conversation';
        _refreshChat(context);
        return;

      case 'model':
        if (parts.length > 1) {
          final modelId = parts[1];
          if (_modelList.any((m) => m['value'] == modelId)) {
            _agent.ai.currentModel = modelId;
            _status = 'Model: $modelId';
          } else {
            _status = 'Unknown model: $modelId';
          }
        } else {
          _startModelSelector(context);
        }
        return;

      case 'models':
        final lines = <String>['', ' Available Models:', ''];
        for (final m in _modelList) {
          final active = _agent.ai.currentModel == m['value'] ? ' ◀ ACTIVE' : '';
          lines.add('   ${m['name']}$active');
        }
        _scroll.setLines(lines);
        _scroll.scrollTop();
        _status = '${_modelList.length} models';
        return;

      case 'acp':
        if (_agent.isAcpRunning) {
          _agent.stopAcpServer().then((_) => _status = 'ACP server stopped');
        } else {
          _agent.startAcpServer()
              .then((_) { _status = 'ACP server running on port ${config.acp.port}'; })
              .catchError((e) { _status = 'ACP error: $e'; });
        }
        return;

      case 'acp-connect':
      case 'acp-connection':
        if (parts.length < 2) {
          _status = 'Usage: /acp-connect <host> <port>  or  /acp-connect cli:<command>';
        } else if (parts[1].startsWith('cli:')) {
          final cmd = parts[1].substring(4);
          final args = parts.length > 2 ? parts.sublist(2) : <String>[];
          _status = 'Spawning $cmd...';
          _agent.connectToAcpCli(cmd, args: args).then((info) {
            final name = info['server_name'] ?? 'acp';
            final model = info['agent_info']?['model'] ?? 'unknown';
            _status = 'ACP: $name ($model) via $cmd';
          }).catchError((e) {
            _status = 'ACP cli error: $e';
          });
        } else if (parts.length >= 3) {
          final host = parts[1];
          final port = int.tryParse(parts[2]);
          if (port == null) {
            _status = 'Invalid port: ${parts[2]}';
          } else {
            _status = 'Connecting to $host:$port...';
            _agent.connectToAcp(host, port).then((info) {
              final name = info['server_name'] ?? 'acp';
              final model = info['agent_info']?['model'] ?? 'unknown';
              _status = 'ACP: $name ($model) @ $host:$port';
            }).catchError((e) { _status = 'ACP connect error: $e'; });
          }
        } else {
          _status = 'Usage: /acp-connect <host> <port>';
        }
        return;

      case 'acp-disconnect':
        if (_agent.isUsingAcp) {
          _agent.disconnectFromAcp().then((_) {
            _status = 'ACP disconnected  ·  ${_agent.ai.currentModel}';
          });
        } else {
          _status = 'Not connected to an ACP provider';
        }
        return;

      case 'list':
        final lines = <String>['', ' Conversations:', ''];
        for (int i = 0; i < _agent.conversations.length; i++) {
          final conv = _agent.conversations[i];
          final active = conv == _agent.activeConversation ? ' ◀' : '';
          final saved = _agent.listSavedSessions().any((s) => s['id'] == conv.id)
              ? ' 💾'
              : '';
          lines.add('   ${i + 1}. ${conv.title}$active$saved');
          // Show session ID for saved convos
          if (conv.id.startsWith('conv_')) {
            lines.add('      ${conv.id}');
          }
        }
        lines.add('');
        lines.add('   /switch <n> to switch  ·  /load <id> to load saved');
        _scroll.setLines(lines);
        _scroll.scrollTop();
        return;

      case 'save':
        _agent.saveCurrentSession().then((_) {
          _status = '✅ Saved (${_agent.activeConversation?.id})';
        }).catchError((e) {
          _status = 'Save failed: $e';
        });
        return;

      case 'load':
        if (parts.length > 1) {
          _agent.loadSession(parts[1]).then((conv) {
            if (conv != null) {
              _status = 'Loaded: ${conv.title}';
              _refreshChat(context);
            } else {
              _status = 'Session not found: ${parts[1]}';
            }
          }).catchError((e) {
            _status = 'Load failed: $e';
          });
        } else {
          // Show list of saved sessions
          final saved = _agent.listSavedSessions();
          if (saved.isEmpty) {
            _status = 'No saved sessions. Use /save first.';
          } else {
            final lines = <String>['', ' Saved Sessions:', ''];
            for (final s in saved) {
              final active = s['id'] == _agent.activeConversation?.id ? ' ◀' : '';
              lines.add('   ${s['id']}  ${s['title']}  (${s['messageCount']} msgs)$active');
            }
            lines.add('');
            lines.add('   /load <id> to load one');
            _scroll.setLines(lines);
            _scroll.scrollTop();
            _status = '${saved.length} saved sessions';
          }
        }
        return;

      case 'phobe':
        try {
          _phobeMode = !_phobeMode;
          _agent.phobeMode = _phobeMode;
          _status = _phobeMode
              ? 'Phobe mode: colors off  (start with --phobe to skip the queer welcome)'
              : '🌈 Pride mode: full queer energy!';
          _refreshChat(context);
        } catch (e) {
          _status = 'Error toggling phobe mode: $e';
        }
        return;

      default:
        _status = 'Unknown: $c  (/help)';
    }
  }

  void _startModelSelector(TuiContext context) {
    _selectingModel = true;
    _selIndex = _modelList.indexWhere((m) => m['value'] == _agent.ai.currentModel);
    if (_selIndex < 0) _selIndex = 0;
    _renderModelSelector(context);
    _status = 'Select a model  ·  ↑↓ navigate  ·  Enter confirm  ·  Esc cancel';
  }

  void _renderModelSelector(TuiContext context) {
    final lines = <String>[
      '',
      ' ═══════════════════════════════════════',
      '           SELECT A MODEL              ',
      ' ═══════════════════════════════════════',
      '',
    ];
    for (int i = 0; i < _modelList.length; i++) {
      final m = _modelList[i];
      final cursor = i == _selIndex ? ' ▸ ' : '   ';
      final active = m['value'] == _agent.ai.currentModel ? '  ◀ active' : '';
      lines.add('$cursor${m['name']}$active');
    }
    lines.addAll([
      '',
      '  (type /model <name> to select by name)',
      '',
    ]);
    _scroll.setLines(lines);
    _scroll.scrollTop();

    // Scroll so the selected model is visible.
    final viewH = context.height - 4; // content area height
    final selectedLine = 5 + _selIndex; // 5 header lines before models
    if (selectedLine >= _scroll.offset + viewH) {
      _scroll.offset = (selectedLine - viewH + 1).clamp(0, lines.length);
    } else if (selectedLine < _scroll.offset) {
      _scroll.offset = selectedLine;
    }
  }

  void _handleModelSelector(TuiKeyEvent event, TuiContext context) {
    switch (event.code) {
      case TuiKeyCode.arrowUp:
        if (_selIndex > 0) {
          _selIndex--;
          _renderModelSelector(context);
        }
        return;
      case TuiKeyCode.arrowDown:
        if (_selIndex < _modelList.length - 1) {
          _selIndex++;
          _renderModelSelector(context);
        }
        return;
      case TuiKeyCode.enter:
        final model = _modelList[_selIndex];
        _agent.ai.currentModel = model['value'] as String;
        _selectingModel = false;
        _status = 'Model: ${model['name']}';
        _refreshChat(context);
        return;
      case TuiKeyCode.escape:
        _selectingModel = false;
        _status = 'Ready  ·  ${_agent.ai.currentModel}';
        _refreshChat(context);
        return;
      default:
        break;
    }
  }

  @override
  void build(TuiContext context) {
    final h = context.height;
    final w = context.width;

    // Status bar (row 0)
    String displayStatus;
    if (_isProcessing && _phobeMode) {
      displayStatus = ' thinking';
    } else if (_isProcessing) {
      const spinners = ['🌈', '✨', '💖', '🏳️\u200d🌈'];
      final s = spinners[_spinnerFrame % spinners.length];
      final dots = List.filled((_spinnerFrame ~/ 4) % 4, '.').join('');
      displayStatus = ' $s thinkin$dots';
    } else {
      displayStatus = ' $_status';
    }

    if (_phobeMode) {
      // Boring gray bar
      TuiBackground(
        style: TuiStyle(bg: 236, fg: 15),
        child: TuiText(displayStatus.padRight(w)),
      ).paint(context, row: 0, col: 0, width: w, height: 1);
    } else {
      // Pride gradient bar
      final prideLen = _prideColors.length;
      for (var i = 0; i < prideLen && i < w; i++) {
        TuiBackground(
          style: TuiStyle(bg: _prideColors[i]),
          child: TuiText(
            i < displayStatus.length ? displayStatus[i] : ' ',
            style: TuiStyle(fg: i == 2 || i == 3 ? 0 : 15),
          ),
        ).paint(context, row: 0, col: i, width: 1, height: 1);
      }
      if (w > prideLen) {
        final remaining = displayStatus.length > prideLen
            ? displayStatus.substring(prideLen)
            : '';
        TuiBackground(
          style: TuiStyle(bg: _prideColors.last),
          child: TuiText(
            remaining.padRight(w - prideLen),
            style: TuiStyle(fg: 15),
          ),
        ).paint(context, row: 0, col: prideLen, width: w - prideLen, height: 1);
      }
    }

    // Multi-line input area
    const maxInputLines = 5;
    final rawInputLineCount = _input.isEmpty
        ? 1
        : '\n'.allMatches(_input).length + 1;
    final inputLineCount = rawInputLineCount.clamp(1, maxInputLines);

    // Chat panel (rows 1 to h-2-inputLineCount)
    final chatH = h - 3 - inputLineCount;
    if (chatH > 0) {
      TuiPanelBox(
        title: '',
        child: _scroll,
        borderStyle: TuiStyle(fg: 238),
        padding: 1,
      ).paint(context, row: 1, col: 0, width: w, height: chatH);
    }

    // Input area (rows h-1-inputLineCount to h-2)
    final inputRow = h - 1 - inputLineCount;
    final promptColor = _phobeMode ? 244 : _prideColors[(_msgCount + 3) % _prideColors.length];
    final inputBg = TuiStyle(bg: 235);

    // Draw input background and each line
    var lineStart = 0;
    for (var line = 0; line < inputLineCount; line++) {
      // Find end of this line
      final lineEnd = _input.indexOf('\n', lineStart);
      final lineText = lineEnd == -1
          ? _input.substring(lineStart)
          : _input.substring(lineStart, lineEnd);

      // Check if cursor is on this line
      final isCursorLine =
          lineStart <= _cursor &&
          _cursor <= (lineEnd == -1 ? _input.length : lineEnd);
      final cursorCol = isCursorLine ? _cursor - lineStart : -1;

      TuiBackground(
        style: inputBg,
        child: TuiRow(
          children: [
            TuiText(line == 0 ? '> ' : '  ', style: TuiStyle(bold: true, fg: promptColor)),
            TuiText(lineText),
            if (cursorCol >= lineText.length)
              TuiText(' ', style: TuiStyle(bg: 255)), // cursor
          ],
          widths: [2, -1, 1],
        ),
      ).paint(context, row: inputRow + line, col: 0, width: w, height: 1);

      lineStart = lineEnd == -1 ? _input.length : lineEnd + 1;
    }

    // Bottom hint bar (row h-1)
    final hint = _selectingModel
        ? ' ↑/↓=select  Enter=confirm  Esc=cancel'
        : (_phobeMode
            ? ' Enter=send  ↑/↓=scroll  /cmd  ^D=quit  ^C=cancel  Alt+Enter=newline  — phobe mode'
            : ' Enter=send  ↑/↓=scroll  /cmd  ^D=quit  ^C=cancel  Alt+Enter=newline  ✦ fabulously queer');
    TuiBackground(
      style: TuiStyle(
        bg: _phobeMode ? 236 : _prideColors[_msgCount % _prideColors.length],
        fg: 15,
      ),
      child: TuiText(hint, style: TuiStyle(bold: true)),
    ).paint(context, row: h - 1, col: 0, width: w, height: 1);
  }

  @override
  void onEvent(TuiEvent event, TuiContext context) {
    if (_quitting) return;

    // Tick events drive the thinking spinner animation
    if (event is TuiTickEvent) {
      if (_isProcessing) {
        _spinnerFrame++;
      }
      return;
    }

    if (event is! TuiKeyEvent) return;

    // Ctrl+C cancels an in-progress agent run
    if (event.code == TuiKeyCode.ctrlC) {
      if (_isProcessing) {
        _isProcessing = false;
        _agent.cancel();
        _status = 'Cancelling...';
      }
      return;
    }

    // Intercept events during model selector mode
    if (_selectingModel) {
      _handleModelSelector(event, context);
      return;
    }

    // Typing — insert character
    if (event.isPrintable) {
      final ch = event.char!;
      // Ignore special control chars that slip through as printable
      if (ch.codeUnits.length == 1 && ch.codeUnitAt(0) < 32) return;
      _input = _input.substring(0, _cursor) + ch + _input.substring(_cursor);
      _cursor++;
      _lastEscapeTime = null;
      return;
    }

    switch (event.code) {
      // Editing
      case TuiKeyCode.escape:
        // Pressing Esc alone starts the Alt+Enter window
        _lastEscapeTime = DateTime.now();
        return;
      case TuiKeyCode.backspace:
        if (_cursor > 0) {
          _input = _input.substring(0, _cursor - 1) + _input.substring(_cursor);
          _cursor--;
        }
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.delete:
        if (_cursor < _input.length) {
          _input = _input.substring(0, _cursor) + _input.substring(_cursor + 1);
        }
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.arrowLeft:
        if (_cursor > 0) _cursor--;
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.arrowRight:
        if (_cursor < _input.length) _cursor++;
        _lastEscapeTime = null;
        return;

      // Submit or newline
      case TuiKeyCode.enter:
        if (_lastEscapeTime != null &&
            DateTime.now().difference(_lastEscapeTime!) < const Duration(milliseconds: 300)) {
          // Alt+Enter — insert literal newline
          _lastEscapeTime = null;
          _input = '${_input.substring(0, _cursor)}\n${_input.substring(_cursor)}';
          _cursor++;
          return;
        }
        _lastEscapeTime = null;
        _submit(context);
        return;

      // Scrolling
      case TuiKeyCode.arrowUp:
        _scroll.scrollBy(-1, context.height - 4, context.width - 4);
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.arrowDown:
        _scroll.scrollBy(1, context.height - 4, context.width - 4);
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.pageUp:
        _scroll.scrollPage(context.height - 4, context.width - 4, false);
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.pageDown:
        _scroll.scrollPage(context.height - 4, context.width - 4);
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.home:
        _scroll.scrollTop();
        _lastEscapeTime = null;
        return;
      case TuiKeyCode.end:
        _scroll.scrollBottom(context.height - 4, context.width - 4);
        _lastEscapeTime = null;
        return;

      default:
        _lastEscapeTime = null;
        break;
    }
  }

  /// Print a summary of the current session to stdout before exiting.
  void printSessionSummary() {
    _agent.saveCurrentSession();

    final conv = _agent.activeConversation;
    if (conv == null) return;

    final model = _agent.ai.currentModel;
    stdout.writeln();
    stdout.writeln('🏳️\u200d🌈  catch u later bestie!');
    if (conv.id.startsWith('conv_')) {
      stdout.writeln('   utopic --load ${conv.id}  to continue');
    }
    stdout.writeln('   model: $model');
    stdout.writeln();
  }
}