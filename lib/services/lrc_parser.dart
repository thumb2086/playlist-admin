class LrcLine {
  final int timeMs;
  final String text;
  LrcLine(this.timeMs, this.text);
}

class LrcParser {
  static List<LrcLine> parse(String content) {
    final lines = <LrcLine>[];
    final regex = RegExp(r'\[(\d+):(\d+)([:.]\d+)?\](.*)');
    for (final line in content.split('\n')) {
      final match = regex.firstMatch(line.trim());
      if (match == null) { continue; }
      final m = int.parse(match.group(1)!);
      final s = int.parse(match.group(2)!);
      int timeMs = m * 60000 + s * 1000;
      final ms = match.group(3);
      if (ms != null) {
        final msVal = ms.replaceAll(RegExp(r'[:.]'), '');
        // 1 位小數是 1/10 秒（舊寫法當 0ms，整句歌詞錯位）。
        if (msVal.length == 1) { timeMs += int.parse(msVal) * 100; }
        else if (msVal.length == 2) { timeMs += int.parse(msVal) * 10; }
        else if (msVal.length == 3) { timeMs += int.parse(msVal); }
      }
      final text = match.group(4)?.trim() ?? '';
      lines.add(LrcLine(timeMs, text));
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }

  static String getCurrentLyric(List<LrcLine> lyrics, int positionMs, {int offsetMs = 0}) {
    if (lyrics.isEmpty) { return ''; }
    final adjusted = positionMs + offsetMs;
    String current = '';
    for (final lrc in lyrics) {
      if (lrc.timeMs <= adjusted) { current = lrc.text; }
      else { break; }
    }
    return current;
  }
}
