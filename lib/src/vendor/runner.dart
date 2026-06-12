import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:utopia_tui/utopia_tui.dart';

/// Application runner that orchestrates the TUI event loop and rendering.
///
/// Vendored from utopia_tui — modified so Ctrl+D exits instead of Ctrl+C.
/// Ctrl+C is passed through as a normal event for the app to handle.
class UtopicRunner {
  final TuiApp app;
  final TuiTerminalInterface terminal;

  StreamSubscription? _tickSub;
  StreamSubscription? _resizeSub;
  StreamSubscription? _keySub;
  late final Completer<void> _stopCompleter;
  bool _stopped = false;

  int _lastWidth = 0;
  int _lastHeight = 0;

  UtopicRunner(this.app, {TuiTerminalInterface? terminal})
    : terminal = terminal ?? TuiTerminal();

  /// Stop the event loop cleanly (e.g. from app.onEvent).
  void stop() {
    if (!_stopped) {
      _stopped = true;
      _stopCompleter.complete();
    }
  }

  Future<void> run() async {
    var ctx = TuiContext(terminal);
    List<String>? lastVisible;
    List<String>? lastStyled;

    try {
      try {
        app.init(ctx);
      } catch (e) {
        print('Error during app initialization: $e');
      }

      terminal.write('\x1b[?1049h');
      terminal.clearScreen();
      terminal.hideCursor();

      _lastWidth = terminal.width;
      _lastHeight = terminal.height;

      stdin.echoMode = false;
      stdin.lineMode = false;

      _keySub = stdin.listen(
        (List<int> bytes) {
          final events = _parseInputBytes(bytes);
          for (final ev in events) {
            // Ctrl+D → quit (like EOF in a normal terminal)
            // Synchronous cleanup then exit — the async stop mechanism
            // leaves the Dart event loop alive and the terminal hangs.
            if (ev.code == TuiKeyCode.ctrlD) {
              stdin.lineMode = true;
              stdin.echoMode = true;
              terminal.write('\x1b[0m');
              terminal.showCursor();
              terminal.write('\x1b[?1049l');
              exit(0);
            }
            try {
              app.onEvent(ev, ctx);
              _redraw(
                ctx,
                refLastVisible: lastVisible,
                refLastStyled: lastStyled,
                outLastVisible: (v) => lastVisible = v,
                outLastStyled: (s) => lastStyled = s,
                forceFull: true,
              );
            } catch (e) {
              try {
                ctx.clear();
                ctx.surface.putText(
                  0,
                  0,
                  'Error: ${e.toString().substring(0, ctx.width.clamp(0, 100))}',
                );
                final frameStyled = ctx.snapshotStyled();
                for (var r = 0; r < 1; r++) {
                  terminal.setCursor(r, 0);
                  terminal.write(frameStyled[r]);
                }
              } catch (_) {}
            }
          }
        },
        onError: (error) {
          if (!_stopped) {
            _stopped = true;
            _stopCompleter.completeError('Input stream error: $error');
          }
        },
      );

      final tickEvery = app.tickInterval;
      if (tickEvery != null) {
        _tickSub =
            Stream.periodic(
              tickEvery,
              (_) => TuiTickEvent(DateTime.now()),
            ).listen(
              (e) {
                try {
                  app.onEvent(e, ctx);
                  _redraw(
                    ctx,
                    refLastVisible: lastVisible,
                    refLastStyled: lastStyled,
                    outLastVisible: (v) => lastVisible = v,
                    outLastStyled: (s) => lastStyled = s,
                    forceFull: false,
                  );
                } catch (e) {
                // Tick errors are non-fatal; continue
              }
              },
              onError: (error) {},
            );
      }

      _resizeSub = Stream.periodic(const Duration(milliseconds: 150)).listen((
        _,
      ) {
        final w = terminal.width;
        final h = terminal.height;
        if (w != _lastWidth || h != _lastHeight) {
          _lastWidth = w;
          _lastHeight = h;
          final e = TuiResizeEvent(w, h);
          ctx = TuiContext(terminal);
          app.onEvent(e, ctx);
          lastVisible = null;
          lastStyled = null;
          terminal.clearScreen();
          _redraw(
            ctx,
            refLastVisible: lastVisible,
            refLastStyled: lastStyled,
            outLastVisible: (v) => lastVisible = v,
            outLastStyled: (s) => lastStyled = s,
            forceFull: true,
          );
        }
      });

      _redraw(
        ctx,
        refLastVisible: lastVisible,
        refLastStyled: lastStyled,
        outLastVisible: (v) => lastVisible = v,
        outLastStyled: (s) => lastStyled = s,
        forceFull: true,
      );
      _stopCompleter = Completer<void>();
      await _stopCompleter.future;
    } finally {
      await _dispose();
    }
  }

  void _redraw(
    TuiContext ctx, {
    List<String>? refLastVisible,
    List<String>? refLastStyled,
    required void Function(List<String>) outLastVisible,
    required void Function(List<String>) outLastStyled,
    bool forceFull = false,
  }) {
    ctx.clear();
    try {
      app.build(ctx);
      ctx.renderDialogOverlay();
    } catch (e) {
      ctx.surface.putText(
        0,
        0,
        'Build Error: ${e.toString().substring(0, (ctx.width - 12).clamp(10, 100))}',
      );
    }

    final frameVisible = ctx.snapshot();
    final frameStyled = ctx.snapshotStyled();

    for (var r = 0; r < frameVisible.length; r++) {
      final lineV = frameVisible[r];
      final prevV = (refLastVisible != null && r < refLastVisible.length)
          ? refLastVisible[r]
          : null;
      final lineS = frameStyled[r];
      final prevS = (refLastStyled != null && r < refLastStyled.length)
          ? refLastStyled[r]
          : null;

      if (forceFull ||
          prevV == null ||
          prevS == null ||
          prevV != lineV ||
          prevS != lineS) {
        terminal.setCursor(r, 0);
        terminal.write(lineS);
      }
    }
    outLastVisible(frameVisible);
    outLastStyled(frameStyled);
  }

  Future<void> _dispose() async {
    await _tickSub?.cancel();
    await _resizeSub?.cancel();
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } catch (_) {}
    await _keySub?.cancel();
    terminal.write('\x1b[0m');
    terminal.showCursor();
    terminal.write('\x1b[?1049l');
  }
}

// --- Async stdin byte-level key parser ---

List<TuiKeyEvent> _parseInputBytes(List<int> bytes) {
  final events = <TuiKeyEvent>[];
  var i = 0;

  while (i < bytes.length) {
    final b = bytes[i];

    if (b == 27) {
      if (i + 1 < bytes.length && bytes[i + 1] == 91) {
        i += 2;
        if (i < bytes.length) {
          final seq = bytes[i];
          i++;
          switch (seq) {
            case 65:
              events.add(const TuiKeyEvent(code: TuiKeyCode.arrowUp));
            case 66:
              events.add(const TuiKeyEvent(code: TuiKeyCode.arrowDown));
            case 67:
              events.add(const TuiKeyEvent(code: TuiKeyCode.arrowRight));
            case 68:
              events.add(const TuiKeyEvent(code: TuiKeyCode.arrowLeft));
            case 72:
              events.add(const TuiKeyEvent(code: TuiKeyCode.home));
            case 70:
              events.add(const TuiKeyEvent(code: TuiKeyCode.end));
            case 51:
              if (i < bytes.length && bytes[i] == 126) {
                i++;
                events.add(const TuiKeyEvent(code: TuiKeyCode.delete));
              }
            case 53:
              if (i < bytes.length && bytes[i] == 126) {
                i++;
                events.add(const TuiKeyEvent(code: TuiKeyCode.pageUp));
              }
            case 54:
              if (i < bytes.length && bytes[i] == 126) {
                i++;
                events.add(const TuiKeyEvent(code: TuiKeyCode.pageDown));
              }
          }
        }
      } else {
        events.add(const TuiKeyEvent(code: TuiKeyCode.escape));
        i++;
      }
    } else if (b == 13 || b == 10) {
      events.add(const TuiKeyEvent(code: TuiKeyCode.enter));
      i++;
    } else if (b == 9) {
      events.add(const TuiKeyEvent(code: TuiKeyCode.tab));
      i++;
    } else if (b == 127 || b == 8) {
      events.add(const TuiKeyEvent(code: TuiKeyCode.backspace));
      i++;
    } else if (b >= 1 && b <= 26) {
      events.add(TuiKeyEvent(code: _ctrlByteToCode(b)));
      i++;
    } else if (b >= 32 && b < 127) {
      events.add(
        TuiKeyEvent(code: TuiKeyCode.printable, char: String.fromCharCode(b)),
      );
      i++;
    } else if (b >= 128) {
      final charLen = _utf8CharLen(b);
      if (i + charLen <= bytes.length) {
        try {
          final ch = utf8.decode(bytes.sublist(i, i + charLen));
          events.add(TuiKeyEvent(code: TuiKeyCode.printable, char: ch));
        } catch (_) {}
        i += charLen;
      } else {
        i++;
      }
    } else {
      i++;
    }
  }

  return events;
}

int _utf8CharLen(int leadByte) {
  if (leadByte < 0xC0) return 1;
  if (leadByte < 0xE0) return 2;
  if (leadByte < 0xF0) return 3;
  return 4;
}

TuiKeyCode _ctrlByteToCode(int byte) {
  const map = <int, TuiKeyCode>{
    1: TuiKeyCode.ctrlA,
    2: TuiKeyCode.ctrlB,
    3: TuiKeyCode.ctrlC,
    4: TuiKeyCode.ctrlD,
    5: TuiKeyCode.ctrlE,
    6: TuiKeyCode.ctrlF,
    7: TuiKeyCode.ctrlG,
    8: TuiKeyCode.ctrlH,
    10: TuiKeyCode.ctrlJ,
    11: TuiKeyCode.ctrlK,
    12: TuiKeyCode.ctrlL,
    14: TuiKeyCode.ctrlN,
    15: TuiKeyCode.ctrlO,
    16: TuiKeyCode.ctrlP,
    17: TuiKeyCode.ctrlQ,
    18: TuiKeyCode.ctrlR,
    19: TuiKeyCode.ctrlS,
    20: TuiKeyCode.ctrlT,
    21: TuiKeyCode.ctrlU,
    22: TuiKeyCode.ctrlV,
    23: TuiKeyCode.ctrlW,
    24: TuiKeyCode.ctrlX,
    25: TuiKeyCode.ctrlY,
    26: TuiKeyCode.ctrlZ,
  };
  return map[byte] ?? TuiKeyCode.unknown;
}
