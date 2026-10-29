import 'dart:io';
import 'dart:async';

/// Raw terminal input handler for TUI
/// Supports arrow keys, Enter, Escape, Ctrl+C, and printable characters
class TuiInput {
  static final TuiInput _instance = TuiInput._internal();
  factory TuiInput() => _instance;
  TuiInput._internal();

  late StreamSubscription<List<int>> _stdinSub;
  final _keyController = StreamController<TuiKeyEvent>.broadcast();
  bool _rawMode = false;

  /// Stream of key events
  Stream<TuiKeyEvent> get onKey => _keyController.stream;

  /// Initialize raw mode input
  void init() {
    if (_rawMode) return;
    stdin.echoMode = false;
    stdin.lineMode = false;
    _rawMode = true;

    _stdinSub = stdin.cast<List<int>>().listen(_handleRawInput);
  }

  /// Dispose and restore terminal
  void dispose() {
    if (!_rawMode) return;
    _stdinSub.cancel();
    stdin.echoMode = true;
    stdin.lineMode = true;
    _rawMode = false;
    _keyController.close();
  }

  void _handleRawInput(List<int> bytes) {
    // Handle ANSI escape sequences (arrow keys, etc.)
    if (bytes.length >= 3 && bytes[0] == 27 && bytes[1] == 91) {
      // ESC [ ...
      final code = bytes[2];
      switch (code) {
        case 65: // Up
          _keyController.add(TuiKeyEvent(TuiKey.up));
          break;
        case 66: // Down
          _keyController.add(TuiKeyEvent(TuiKey.down));
          break;
        case 67: // Right
          _keyController.add(TuiKeyEvent(TuiKey.right));
          break;
        case 68: // Left
          _keyController.add(TuiKeyEvent(TuiKey.left));
          break;
        case 72: // Home
          _keyController.add(TuiKeyEvent(TuiKey.home));
          break;
        case 70: // End
          _keyController.add(TuiKeyEvent(TuiKey.end));
          break;
        case 51: // Delete (ESC [ 3 ~)
          if (bytes.length >= 4 && bytes[3] == 126) {
            _keyController.add(TuiKeyEvent(TuiKey.delete));
          }
          break;
        case 53: // Page Up (ESC [ 5 ~)
          if (bytes.length >= 4 && bytes[3] == 126) {
            _keyController.add(TuiKeyEvent(TuiKey.pageUp));
          }
          break;
        case 54: // Page Down (ESC [ 6 ~)
          if (bytes.length >= 4 && bytes[3] == 126) {
            _keyController.add(TuiKeyEvent(TuiKey.pageDown));
          }
          break;
      }
      return;
    }

    // Handle single byte keys
    if (bytes.length == 1) {
      final byte = bytes[0];
      switch (byte) {
        case 13: // Enter
        case 10:
          _keyController.add(TuiKeyEvent(TuiKey.enter));
          break;
        case 27: // Escape
          _keyController.add(TuiKeyEvent(TuiKey.escape));
          break;
        case 3: // Ctrl+C
          _keyController.add(TuiKeyEvent(TuiKey.ctrlC));
          break;
        case 12: // Ctrl+L (redraw)
          _keyController.add(TuiKeyEvent(TuiKey.ctrlL));
          break;
        case 9: // Tab
          _keyController.add(TuiKeyEvent(TuiKey.tab));
          break;
        case 127: // Backspace
        case 8:
          _keyController.add(TuiKeyEvent(TuiKey.backspace));
          break;
        default:
          if (byte >= 32 && byte <= 126) {
            _keyController.add(TuiKeyEvent(TuiKey.char, char: String.fromCharCode(byte)));
          }
          break;
      }
    }
  }

  /// Wait for a single key event
  Future<TuiKeyEvent> waitForKey() async {
    return await _keyController.stream.first;
  }
}

/// Key event for TUI
class TuiKeyEvent {
  final TuiKey key;
  final String? char;

  TuiKeyEvent(this.key, {this.char});

  @override
  String toString() => 'TuiKeyEvent($key${char != null ? ': $char' : ''})';
}

/// TUI key codes
enum TuiKey {
  up,
  down,
  left,
  right,
  enter,
  escape,
  ctrlC,
  ctrlL,
  tab,
  backspace,
  home,
  end,
  pageUp,
  pageDown,
  delete,
  char,
}