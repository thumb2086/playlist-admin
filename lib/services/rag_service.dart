import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'config_service.dart';

/// RAG 索引服務 — 透過 Python bridge 執行 rag/build_db.py（增量）。
/// 問答不再走 GUI 頁面，改用 opencode（podcast-knowledge skill）。
class RagService {
  static RagService? _instance;
  static RagService get instance => _instance ??= RagService._();
  RagService._();

  /// 同一時間只允許一個 build：音樂 + Podcast 兩條 pipeline 結尾都會調 build，
  /// 同時跑會開兩個 python 進程寫同一個 ChromaDB（SQLite lock）+ 同時打 Ollama。
  static bool _building = false;

  /// 增量重建 RAG 索引；逐行回傳進度。
  Future<void> build(void Function(String line) onLog) async {
    if (_building) {
      onLog('RAG 已在建立中（另一條 pipeline），本次跳過，下次自動補上');
      return;
    }
    _building = true;
    try {
      await _buildInner(onLog);
    } finally {
      _building = false;
    }
  }

  Future<void> _buildInner(void Function(String line) onLog) async {
    final basePath = ConfigService.instance.config.basePath;
    final ragScript = '$basePath\\rag\\build_db.py';
    if (!File(ragScript).existsSync()) {
      onLog('找不到 rag/build_db.py，跳過 RAG');
      return;
    }
    final env = Map<String, String>.from(Platform.environment);
    env['PYTHONIOENCODING'] = 'utf-8';
    env['PYTHONUNBUFFERED'] = '1';
    if (basePath.isNotEmpty) env['BASE_PATH'] = basePath;
    final proc = await Process.start(
      'python',
      // workers 4 而非 8：bge-m3 embedding 吃 CPU，兩條 pipeline 一起跑時
      // 留一點 CPU 給 UI thread，否則介面會被餓死卡住。
      ['-X', 'utf8', ragScript, '--batch', '64', '--workers', '4'],
      runInShell: true,
      workingDirectory: basePath.isNotEmpty ? basePath : Directory.current.path,
      environment: env,
    );
    final completer = Completer<void>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.trim().isEmpty) return;
      try {
        final json = jsonDecode(line.trim()) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'log') onLog(json['message'] as String? ?? '');
        if (type == 'error' && !completer.isCompleted) {
          completer.completeError(Exception(json['message'] as String? ?? 'RAG 重建失敗'));
        }
        if (type == 'complete' && !completer.isCompleted) completer.complete();
      } catch (_) {
        onLog(line.trim());
      }
    });
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.trim().isNotEmpty) onLog(line.trim());
    });
    await proc.exitCode;
    if (!completer.isCompleted) {
      completer.complete();
    }
    await completer.future;
  }
}
