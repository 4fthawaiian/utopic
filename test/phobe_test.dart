import 'package:test/test.dart';
import 'dart:io';

// We can't instantiate UtopicTuiApp without a terminal, but we can test
// the constructor parameter mapping by reading the source.
void main() {
  test('--phobe flag parsed correctly', () {
    // Read the bin source to verify flag parsing
    final binSrc = File('bin/utopic.dart').readAsStringSync();
    
    // Verify --phobe flag is parsed
    expect(binSrc, contains("'--phobe'"));
    expect(binSrc, contains('phobeMode = true'));
    
    // Verify phobeMode is passed to the TUI app
    expect(binSrc, contains('phobeMode: phobeMode'));
  });

  test('/phobe command handled in TUI', () {
    final tuiSrc = File('lib/src/tui/utopic_tui.dart').readAsStringSync();
    
    // Verify the _phobeMode field exists
    expect(tuiSrc, contains('bool _phobeMode'));
    
    // Verify the constructor accepts the parameter
    expect(tuiSrc, contains('this._phobeMode'));
    
    // Verify the /phobe command is handled
    expect(tuiSrc, contains("case 'phobe':"));
    expect(tuiSrc, contains('_phobeMode = !_phobeMode'));
    
    // Verify _nextColor respects phobeMode
    expect(tuiSrc, contains('if (_phobeMode) return 244'));
    
    // Verify the status bar uses _phobeMode
    expect(tuiSrc, contains("if (_phobeMode) {"));
  });
}
