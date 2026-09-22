import 'dart:async';
import 'dart:io';
import '../version.dart';

class LogManager {
  static final LogManager _instance = LogManager._();
  static LogManager get instance => _instance;
  LogManager._();

  String? _logPath;
  int _maxFiles = 10;
  bool _enabled = false;
  // 常駐 sink：舊寫法每行 open-write-close 同步寫，高頻 log 很傷主 thread。
  IOSink? _sink;
  Timer? _flushTimer;

  void enable(String basePath, {int maxFiles = 10}) {
    _maxFiles = maxFiles;
    _enabled = true;
    final logDir = Directory('$basePath\\logs');
    logDir.createSync(recursive: true);
    final now = DateTime.now();
    final name = 'session_${now.year}${_p2(now.month)}${_p2(now.day)}_'
        '${_p2(now.hour)}${_p2(now.minute)}${_p2(now.second)}.log';
    _logPath = '${logDir.path}\\$name';
    _cleanup(logDir.path);
    info('--- 系統啟動 v$appVersion ---');
  }

  String _p2(int n) => n.toString().padLeft(2, '0');

  void _cleanup(String dirPath) {
    try {
      final dir = Directory(dirPath);
      final files = dir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      while (files.length >= _maxFiles) {
        files.removeAt(0).deleteSync();
      }
    } catch (_) {}
  }

  void info(String msg) => _write('INFO', msg);
  void error(String msg) => _write('ERROR', msg);

  void _write(String level, String msg) {
    if (!_enabled || _logPath == null) return;
    try {
      _sink ??= File(_logPath!).openWrite(mode: FileMode.append);
      final now = DateTime.now();
      _sink!.writeln('[${now.hour}:${_p2(now.minute)}:${_p2(now.second)}] [$level] $msg');
      // 5s flush 一次：crash 最多丟 5 秒 log，換來不卡主 thread。
      if (_flushTimer?.isActive ?? false) return;
      _flushTimer = Timer(const Duration(seconds: 5), () async {
        try { await _sink?.flush(); } catch (_) {}
      });
    } catch (_) {}
  }
}
