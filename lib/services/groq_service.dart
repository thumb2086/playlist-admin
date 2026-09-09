import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'groq_native_service.dart';

class GroqService {
  static GroqService? _instance;
  static GroqService get instance => _instance ??= GroqService._();
  GroqService._();

  String _keysCsv = '';
  String _model = 'whisper-large-v3-turbo';
  final List<int> _callTimes = [];

  void setApiKey(String csv) { _keysCsv = csv; }
  String? get apiKey => _keysCsv.isNotEmpty ? _keysCsv.split(',')[0].trim() : null;
  int get keyCount => _keysCsv.split(',').where((k) => k.trim().isNotEmpty).length;
  String get defaultModel => _model;

  List<List<int>> get rpmHistory {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    final counts = <int, int>{};
    for (final t in _callTimes) {
      final m = (now - t ~/ 60000).clamp(0, 59);
      counts[m] = (counts[m] ?? 0) + 1;
    }
    final result = <List<int>>[];
    for (int i = 59; i >= 0; i--) {
      result.add([59 - i, counts[i] ?? 0]);
    }
    return result;
  }

  void _recordCall() {
    _callTimes.add(DateTime.now().millisecondsSinceEpoch);
    if (_callTimes.length > 5000) _callTimes.removeRange(0, _callTimes.length - 5000);
  }

  Future<void> loadFromEnv() async {
    final f = File('.env');
    if (!await f.exists()) return;
    try {
      for (final line in await f.readAsLines()) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('#')) continue;
        final eq = l.indexOf('=');
        if (eq <= 0) continue;
        final k = l.substring(0, eq).trim();
        final v = l.substring(eq + 1).trim();
        if (k == 'GROQ_API_KEY' && v.isNotEmpty) {
          _keysCsv = v;
        } else if (k == 'GROQ_MODEL' && v.isNotEmpty) {
          _model = v;
        }
      }
    } catch (e) { debugPrint('[Groq] .env error: $e'); }
  }

  /// Native Groq transcription — auto-chunks files > 20MB, no Python bridge needed.
  Future<String> transcribeFile({
    required String filePath, required String model, String? language,
    void Function(String chunk, double pct)? onChunk,
  }) async {
    _recordCall();
    if (_keysCsv.isEmpty) throw Exception('請先設定 Groq API Key');
    if (!File(filePath).existsSync()) throw Exception('檔案不存在: $filePath');

    final svc = GroqNativeService.instance;
    svc.setApiKey(_keysCsv);

    onChunk?.call('正在上傳音檔…', 0.1);
    final text = await svc.transcribeAutoChunk(
      filePath, model: model, language: language,
      onChunk: (msg, pct) => onChunk?.call(msg, pct),
    );
    onChunk?.call('轉錄完成', 1.0);
    return text;
  }

  static const models = ['whisper-large-v3', 'whisper-large-v3-turbo'];
  static const languages = ['', 'zh', 'en', 'ja', 'ko', 'es', 'fr', 'de', 'th', 'vi'];
}
