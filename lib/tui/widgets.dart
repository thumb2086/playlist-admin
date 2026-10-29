import 'dart:io' as io;

import 'package:ansi_styles/ansi_styles.dart';
import 'package:ansi_styles/extension.dart';
import 'package:term_glyph/term_glyph.dart' as glyph;
import 'input.dart';

/// ANSI escape codes for terminal control
class Ansi {
  static const String reset = '\x1b[0m';
  static const String clear = '\x1b[2J';
  static const String clearLine = '\x1b[2K';
  static const String cursorHome = '\x1b[H';
  static const String cursorHide = '\x1b[?25l';
  static const String cursorShow = '\x1b[?25h';
  static const String cursorUp = '\x1b[A';
  static const String cursorDown = '\x1b[B';
  static const String saveCursor = '\x1b[s';
  static const String restoreCursor = '\x1b[u';
  static const String altScreenEnter = '\x1b[?1049h';
  static const String altScreenExit = '\x1b[?1049l';

  static String moveTo(int row, int col) => '\x1b[${row};${col}H';
  static String moveUp(int n) => '\x1b[${n}A';
  static String moveDown(int n) => '\x1b[${n}B';
  static String eraseInLine(int n) => '\x1b[${n}K';
}

/// Terminal size helper
class TermSize {
  static int get width => io.stdout.terminalColumns;
  static int get height => io.stdout.terminalLines;
}

/// Base TUI widget
abstract class TuiWidget {
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width});
  Size get preferredSize;
}

/// Size class
class Size {
  final int width;
  final int height;
  const Size(this.width, this.height);
}

/// Border characters
class Borders {
  static const String tl = '┌';
  static const String tr = '┐';
  static const String bl = '└';
  static const String br = '┘';
  static const String h = '─';
  static const String v = '│';
  static const String teeT = '┬';
  static const String teeB = '┴';
  static const String teeL = '├';
  static const String teeR = '┤';
  static const String cross = '┼';
}

/// Pre-computed styled borders for performance
class StyledBorders {
  final String tl, tr, bl, br, h, v, teeT, teeB, teeL, teeR, cross;
  
  StyledBorders._(this.tl, this.tr, this.bl, this.br, this.h, this.v,
                   this.teeT, this.teeB, this.teeL, this.teeR, this.cross);
  
  factory StyledBorders.dim() => StyledBorders._(
    AnsiStyles.dim.call(Borders.tl),
    AnsiStyles.dim.call(Borders.tr),
    AnsiStyles.dim.call(Borders.bl),
    AnsiStyles.dim.call(Borders.br),
    AnsiStyles.dim.call(Borders.h),
    AnsiStyles.dim.call(Borders.v),
    AnsiStyles.dim.call(Borders.teeT),
    AnsiStyles.dim.call(Borders.teeB),
    AnsiStyles.dim.call(Borders.teeL),
    AnsiStyles.dim.call(Borders.teeR),
    AnsiStyles.dim.call(Borders.cross),
  );
  
  factory StyledBorders.plain() => StyledBorders._(
    Borders.tl, Borders.tr, Borders.bl, Borders.br,
    Borders.h, Borders.v, Borders.teeT, Borders.teeB,
    Borders.teeL, Borders.teeR, Borders.cross,
  );
}

/// Menu widget with keyboard navigation
class MenuWidget extends TuiWidget {
  final List<MenuItem> items;
  int selectedIndex = 0;
  final String? title;
  final bool showNumbers;

  MenuWidget({
    required this.items,
    this.title,
    this.showNumbers = true,
  });

  @override
  Size get preferredSize {
    int h = items.length;
    if (title != null) h += 2;
    return Size(0, h); // width 0 = auto
  }

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? TermSize.width;

    if (title != null) {
      sb.write(Ansi.moveTo(currentY, x));
      sb.write(AnsiStyles.bold.call(title!));
      currentY++;
      // Separator
      sb.write(Ansi.moveTo(currentY, x));
      sb.write(Borders.h * (w - 2));
      currentY++;
    }

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final isSelected = i == selectedIndex;
      sb.write(Ansi.moveTo(currentY, x));

      final prefix = isSelected ? '► ' : '  ';
      final numPrefix = showNumbers ? '${i + 1}. ' : '';

      if (isSelected) {
        sb.write(AnsiStyles.inverse.call('$prefix$numPrefix${item.label}'));
      } else {
        sb.write('$prefix$numPrefix${item.label}');
      }
      if (item.shortcut != null) {
        sb.write(' ${AnsiStyles.dim.call('[${item.shortcut}]')}');
      }
      currentY++;
    }
  }

  void moveUp() {
    selectedIndex = (selectedIndex - 1).clamp(0, items.length - 1);
  }

  void moveDown() {
    selectedIndex = (selectedIndex + 1).clamp(0, items.length - 1);
  }

  MenuItem? get selected => items.isEmpty ? null : items[selectedIndex];
}

/// Menu item
class MenuItem {
  final String label;
  final String? shortcut;
  final void Function()? onSelect;
  final bool enabled;

  MenuItem({
    required this.label,
    this.shortcut,
    this.onSelect,
    this.enabled = true,
  });
}

/// Progress bar widget
class ProgressBar extends TuiWidget {
  final double progress; // 0.0 - 1.0
  final int width;
  final String label;
  final bool showPercent;

  ProgressBar({
    required this.progress,
    this.width = 40,
    this.label = '',
    this.showPercent = true,
  });

  @override
  Size get preferredSize => Size(width + 10, label.isEmpty ? 1 : 2);

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    sb.write(Ansi.moveTo(y, x));

    if (label.isNotEmpty) {
      sb.write(label);
      sb.write('\n');
      sb.write(Ansi.moveTo(y + 1, x));
    }

    final int w = width ?? this.width;
    final int filled = (progress.clamp(0.0, 1.0) * w).round();
    final int empty = w - filled;

    sb.write('[');
    sb.write(AnsiStyles.bgGreen.call('█' * filled));
    sb.write(AnsiStyles.bgBlack.call('░' * empty));
    sb.write(']');

    if (showPercent) {
      sb.write(' ${(progress * 100).toStringAsFixed(1)}%');
    }
  }
}

/// Status panel widget
class StatusPanel extends TuiWidget {
  final Map<String, String> fields;
  final String title;
  final int width;

  StatusPanel({
    required this.fields,
    this.title = 'Status',
    this.width = 40,
  });

  @override
  Size get preferredSize => Size(width, fields.length + 3);

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? this.width;

    // Top border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.tl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.tr));
    currentY++;

    // Title
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    sb.write(' ');
    sb.write(AnsiStyles.bold.underline.call(title.padRight(w - 4)));
    sb.write(' ');
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Fields
    for (final entry in fields.entries) {
      sb.write(Ansi.moveTo(currentY, x));
      sb.write(AnsiStyles.dim.call(Borders.v));
      sb.write(' ');
      sb.write(AnsiStyles.cyan.call('${entry.key}:'.padRight(16)));
      sb.write(AnsiStyles.white.call(entry.value.padRight(w - 22)));
      sb.write(' ');
      sb.write(AnsiStyles.dim.call(Borders.v));
      currentY++;
    }

    // Bottom border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.bl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.br));
  }
}

/// Log panel widget (scrollable)
class LogPanel extends TuiWidget {
  final List<String> lines;
  final int maxLines;
  final int width;
  final int height;
  int scrollOffset = 0;
  final StyledBorders borders;

  LogPanel({
    required this.lines,
    this.maxLines = 1000,
    this.width = 80,
    this.height = 20,
    StyledBorders? borders,
  }) : borders = borders ?? StyledBorders.dim();

  @override
  Size get preferredSize => Size(width, height);

  void scrollUp() {
    if (scrollOffset > 0) scrollOffset--;
  }

  void scrollDown() {
    final int maxScroll = (lines.length - (height - 2)).clamp(0, lines.length);
    if (scrollOffset < maxScroll) scrollOffset++;
  }

  void scrollToBottom() {
    scrollOffset = (lines.length - (height - 2)).clamp(0, lines.length);
  }

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? this.width;
    int h = height;

    // Top border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(borders.tl);
    sb.write(borders.h * (w - 2));
    sb.write(borders.tr);
    currentY++;

    // Content lines
    final visibleLines = lines.length - scrollOffset;
    final showCount = (h - 2).clamp(0, visibleLines);

    for (int i = 0; i < showCount; i++) {
      final lineIndex = scrollOffset + i;
      if (lineIndex >= lines.length) break;

      sb.write(Ansi.moveTo(currentY, x));
      sb.write(borders.v);
      
      final line = lines[lineIndex];
      // Truncate or pad
      final display = line.length > w - 4
          ? line.substring(0, w - 4)
          : line.padRight(w - 4);
      sb.write(' $display ');

      sb.write(Ansi.moveTo(currentY, x + w - 1));
      sb.write(borders.v);

      currentY++;
    }

    // Fill remaining with empty lines
    for (int i = showCount; i < h - 2; i++) {
      sb.write(Ansi.moveTo(currentY, x));
      sb.write(borders.v);
      sb.write(' ' * (w - 2));
      sb.write(borders.v);
      currentY++;
    }

    // Bottom border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(borders.bl);
    sb.write(borders.h * (w - 2));
    sb.write(borders.br);
  }
}

/// Input dialog widget
class InputDialog extends TuiWidget {
  final String prompt;
  String value = '';
  final int width;
  bool _finished = false;
  String? _result;

  InputDialog({
    required this.prompt,
    this.width = 50,
  });

  @override
  Size get preferredSize => Size(width, 5);

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? this.width;

    // Top border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.tl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.tr));
    currentY++;

    // Prompt
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    sb.write(' ');
    sb.write(AnsiStyles.bold.call(prompt));
    currentY++;

    // Input line
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    sb.write(' ');
    sb.write(value.padRight(w - 4));
    sb.write(' ');
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Bottom border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.bl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.br));
  }

  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.enter:
        _finished = true;
        _result = value;
        break;
      case TuiKey.escape:
        _finished = true;
        _result = null;
        break;
      case TuiKey.backspace:
        if (value.isNotEmpty) value = value.substring(0, value.length - 1);
        break;
      case TuiKey.char:
        if (event.char != null && value.length < width - 4) {
          value += event.char!;
        }
        break;
      default:
        break;
    }
  }

  bool get isFinished => _finished;
  String? get result => _result;
  void reset() {
    _finished = false;
    _result = null;
    value = '';
  }
}

/// Confirmation dialog
class ConfirmDialog extends TuiWidget {
  final String message;
  final int width;
  int selected = 0; // 0 = Yes, 1 = No
  bool _finished = false;
  bool? _result;

  ConfirmDialog({
    required this.message,
    this.width = 50,
  });

  @override
  Size get preferredSize => Size(width, 7);

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? this.width;

    // Top border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.tl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.tr));
    currentY++;

    // Empty line
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    sb.write(' ' * (w - 2));
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Message (centered)
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    final padding = ((w - 4 - message.length) / 2).floor();
    sb.write(' ' * padding);
    sb.write(message);
    sb.write(' ' * (w - 4 - message.length - padding));
    sb.write(' ');
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Empty line
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));
    sb.write(' ' * (w - 2));
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Buttons
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.v));

    final btnYes = selected == 0 ? '[ Yes ]' : '  Yes  ';
    final btnNo = selected == 1 ? '[ No  ]' : '  No   ';
    final btnWidth = btnYes.length + btnNo.length + 2;
    final startX = ((w - 4 - btnWidth) / 2).floor();

    sb.write(' ' * startX);
    sb.write(selected == 0 ? AnsiStyles.inverse.call(btnYes) : btnYes);
    sb.write('  ');
    sb.write(selected == 1 ? AnsiStyles.inverse.call(btnNo) : btnNo);

    sb.write(' ' * (w - 4 - startX - btnWidth));
    sb.write(AnsiStyles.dim.call(Borders.v));
    currentY++;

    // Bottom border
    sb.write(Ansi.moveTo(currentY, x));
    sb.write(AnsiStyles.dim.call(Borders.bl));
    sb.write(AnsiStyles.dim.call(Borders.h * (w - 2)));
    sb.write(AnsiStyles.dim.call(Borders.br));
  }

  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.left:
      case TuiKey.right:
      case TuiKey.tab:
        selected = 1 - selected;
        break;
      case TuiKey.enter:
        _finished = true;
        _result = selected == 0;
        break;
      case TuiKey.escape:
        _finished = true;
        _result = false;
        break;
      default:
        break;
    }
  }

  bool get isFinished => _finished;
  bool? get result => _result;
  void reset() {
    _finished = false;
    _result = null;
    selected = 0;
  }
}

/// Help/Shortcuts panel
class HelpPanel extends TuiWidget {
  final List<(String, String)> shortcuts; // (key, description)
  final int width;

  HelpPanel({
    required this.shortcuts,
    this.width = 40,
  });

  @override
  Size get preferredSize => Size(width, shortcuts.length + 2);

  @override
  void render(StringBuffer sb, {int x = 0, int y = 0, int? width}) {
    int currentY = y;
    int w = width ?? this.width;

    for (int i = 0; i < shortcuts.length; i++) {
      sb.write(Ansi.moveTo(currentY, x));
      sb.write(AnsiStyles.cyan.bold.call(shortcuts[i].$1.padRight(12)));
      sb.write(shortcuts[i].$2);
      currentY++;
    }
  }
}

/// Screen base class
abstract class TuiScreen {
  String get title;
  void onEnter();
  void onExit();
  void handleKey(TuiKeyEvent event);
  void render(StringBuffer sb);
  bool get wantsExit => false;
}

/// Screen manager
class ScreenManager {
  final List<TuiScreen> _stack = [];
  final StringBuffer _sb = StringBuffer();

  void push(TuiScreen screen) {
    if (_stack.isNotEmpty) _stack.last.onExit();
    _stack.add(screen);
    screen.onEnter();
  }

  void pop() {
    if (_stack.isNotEmpty) {
      _stack.last.onExit();
      _stack.removeLast();
      if (_stack.isNotEmpty) _stack.last.onEnter();
    }
  }

  void replace(TuiScreen screen) {
    if (_stack.isNotEmpty) _stack.last.onExit();
    _stack.clear();
    _stack.add(screen);
    screen.onEnter();
  }

  TuiScreen? get current => _stack.isEmpty ? null : _stack.last;

  int get stackDepth => _stack.length;

  void handleKey(TuiKeyEvent event) {
    current?.handleKey(event);
  }

  void render() {
    _sb.clear();
    _sb.write(Ansi.clear);
    _sb.write(Ansi.cursorHome);
    current?.render(_sb);
    io.stdout.write(_sb.toString());
  }

  void clear() {
    _sb.clear();
    _sb.write(Ansi.clear);
    _sb.write(Ansi.cursorHome);
    io.stdout.write(_sb.toString());
  }
}