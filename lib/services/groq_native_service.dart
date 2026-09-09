import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logger/logger.dart';
import 'config_service.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// 不可重試的 Groq HTTP 錯誤（400/401/413 等）：直接 rethrow，不進重試。
/// （舊寫法用字串比對 status code，'0' 對任何含 0 的訊息恆真，
/// 會把 400 也當 transient 空轉好幾分鐘。）
class _GroqFatalException implements Exception {
  final int status;
  final String body;
  _GroqFatalException(this.status, this.body);
  @override
  String toString() => 'Groq 失敗 $status: $body';
}

/// Groq REST API 原生 Dart 客戶端（取代 Python bridge）。
/// 直接呼叫 api.groq.com，不需要 Python/yt-dlp。
///
/// 支援多 API Key 輪替、429/5xx 自動重試、音檔自動分段、代理、錯誤日誌。
class GroqNativeService {
  GroqNativeService._();
  static final instance = GroqNativeService._();

  // ── API Key 管理 ──────────────────────────────────────
  List<String> _keys = [];
  int _keyIndex = 0;

  /// 設定 API Key（可傳入 CSV 格式的多 key）。
  void setApiKey(String keysCsv) {
    _keys = keysCsv.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    _keyIndex = 0;
  }

  String get apiKey => _keys.isNotEmpty ? _keys.first : '';
  bool get hasApiKey => _keys.isNotEmpty;
  int get keyCount => _keys.length;

  /// 取得目前輪替中的 key，並推進到下一個。
  String _nextKey() {
    if (_keys.isEmpty) throw Exception('未設定 Groq API Key');
    final key = _keys[_keyIndex % _keys.length];
    _keyIndex++;
    return key;
  }

  Future<void> loadFromEnv() async {
    // String.fromEnvironment 讀的是編譯期 --dart-define，不是 OS 環境變數：
    // 兩個都查，OS env 優先。
    final osKey = Platform.environment['GROQ_API_KEY'] ?? '';
    if (osKey.isNotEmpty) {
      _keys = [osKey];
      return;
    }
    const defineKey = String.fromEnvironment('GROQ_API_KEY', defaultValue: '');
    if (defineKey.isNotEmpty) _keys = [defineKey];
  }

  /// 启动时 async 查 proxy（不堵塞第一次请求）。
  Future<void> preloadProxy() async {
    if (_proxyResolved) return;
    // 只從環境變數讀 proxy（不讀 Windows Registry，因為不可靠）
    for (final name in ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy']) {
      final v = Platform.environment[name];
      if (v != null && v.isNotEmpty) {
        _cachedProxy = v;
        _proxyResolved = true;
        return;
      }
    }
    _proxyResolved = true;
  }

  // ── 常量 ──────────────────────────────────────────────
  /// Groq 免費方案音檔大小上限（bytes）
  static const int _maxFileSize = 20 * 1024 * 1024; // 20 MB
  /// 分段秒數（5 分鐘）
  static const int _chunkDurationSec = 300;
  /// 二次分段秒數（60 秒，處理 5 分鐘段仍過大的情況）
  static const int _subChunkDurationSec = 60;
  /// 最大重試次數（每個 key 嘗試一次，外加 2 次額外重試）
  static const int _maxRetries = 2;

  // ── HTTP 狀態碼分類 ──────────────────────────────────
  static const _retryableStatuses = {0, 429, 500, 502, 503};

  // ── 代理 (Proxy) 支援 ────────────────────────────────
  String? _cachedProxy;
  bool _proxyResolved = false;
  http.Client? _cachedClient;
  static bool _proxyCertWarned = false;

  /// 從環境變數或 Windows Registry 讀取代理設定（只查一次，結果快取）。
  String? _resolveProxy() {
    if (_proxyResolved) return _cachedProxy;
    // 1. 嘗試環境變數
    for (final name in ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy']) {
      final v = Platform.environment[name];
      if (v != null && v.isNotEmpty) {
        _cachedProxy = v;
        _proxyResolved = true;
        return _cachedProxy;
      }
    }
    // 2. 嘗試 Windows Registry（async，不堵塞 event loop）
    _proxyResolved = true;
    _cachedProxy = null;
    return _cachedProxy;
  }

  /// 設定代理 URL（從外部 async 查好後傳入）。
  void setProxy(String? proxy) {
    _cachedProxy = proxy;
    _proxyResolved = true;
  }

  /// 建立支援代理的 HTTP Client（快取，不重複建立）。
  http.Client _createClient() {
    if (_cachedClient != null) return _cachedClient!;
    final proxy = _resolveProxy();
    if (proxy == null) {
      _cachedClient = http.Client();
      return _cachedClient!;
    }

    try {
      final proxyUri = Uri.parse(proxy);
      final proxyHost = proxyUri.host;
      final proxyPort = proxyUri.port;
      final httpClient = HttpClient();
      httpClient.findProxy = (uri) {
        return 'PROXY $proxyHost:$proxyPort';
      };
      // 忽略 SSL 憑證錯誤（代理常見問題）。注意：代理可見明文流量
      // （含 API key），僅在信任的網路使用代理。
      if (!_proxyCertWarned) {
        _proxyCertWarned = true;
        _log.w('[Groq] 代理模式略過 TLS 憑證驗證，僅信任的網路可使用代理');
      }
      httpClient.badCertificateCallback = (cert, host, port) => true;
      _cachedClient = IOClient(httpClient);
    } catch (e) {
      _log.w('[Groq] 代理設定解析失敗: $e，使用直接連線');
      _cachedClient = http.Client();
    }
    return _cachedClient!;
  }

  // ── 錯誤日誌 ─────────────────────────────────────────
  /// 將轉錄錯誤寫入 stt_errors.log。
  static Future<void> _logError({
    required String audioPath,
    required int statusCode,
    required String responseBody,
    Exception? error,
    required int keysTried,
  }) async {
    try {
      final logDir = Directory('${Directory.current.path}\\logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);
      final logFile = File('${logDir.path}\\stt_errors.log');
      final now = DateTime.now();
      final ts = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      final fileSize = await File(audioPath).exists() ? await File(audioPath).length() : 0;
      final sb = StringBuffer()
        ..writeln('\n--- $ts ---')
        ..writeln('File: $audioPath')
        ..writeln('Size: ${fileSize ~/ 1024}KB')
        ..writeln('Status: $statusCode')
        ..writeln('Body: ${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}')
        ..writeln('Error: ${error != null ? error.toString().substring(0, error.toString().length.clamp(0, 300)) : "none"}')
        ..writeln('Keys tried: $keysTried');
      await logFile.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  // ── 單檔轉錄（含重試 + key 輪替） ───────────────────
  /// Whisper 語音轉文字。遇到 429/5xx 時自動換 key 重試。
  Future<String> transcribe(
    String filePath, {
    String model = 'whisper-large-v3-turbo',
    String? language,
  }) async {
    if (_keys.isEmpty) throw Exception('未設定 Groq API Key');

    final totalAttempts = _keys.length + _maxRetries;
    Exception? lastError;
    String lastBody = '';
    int lastStatus = 0;

    for (int attempt = 0; attempt < totalAttempts; attempt++) {
      final key = _nextKey();
      http.Client? client;
      try {
        client = _createClient();
        final file = await http.MultipartFile.fromPath('file', filePath);
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
        )
          ..headers['Authorization'] = 'Bearer $key'
          ..fields['model'] = model
          ..fields['response_format'] = 'verbose_json'
          ..files.add(file);

        final streamedResponse = await client.send(request).timeout(const Duration(seconds: 300));
        final body = await streamedResponse.stream.bytesToString();
        final sc = streamedResponse.statusCode;
        lastBody = body;
        lastStatus = sc;

        if (sc == 200) {
          final data = jsonDecode(body);
          return data['text'] as String? ?? '';
        }

        // 可重試的錯誤：429 (Rate Limit), 5xx (Server Error), 0 (無回應)
        if (_retryableStatuses.contains(sc)) {
          final delay = Duration(seconds: 3 + attempt * 3);
          _log.w('[Groq] HTTP $sc，第 ${attempt + 1}/$totalAttempts 次重試，等待 ${delay.inSeconds}s');
          await Future<void>.delayed(delay);
          lastError = Exception('Groq 轉錄失敗 $sc: $body');
          continue;
        }

        // 不可重試的錯誤（400, 401, 413 等）：typed exception，
        // catch 端直接 rethrow，不做字串比對。
        throw _GroqFatalException(sc, body);
      } on TimeoutException {
        final delay = Duration(seconds: 3 + attempt * 3);
        _log.w('[Groq] 逾時，第 ${attempt + 1}/$totalAttempts 次重試');
        await Future<void>.delayed(delay);
        lastError = Exception('Groq 轉錄逾時 (${filePath.split('\\').last})');
      } on SocketException catch (e) {
        final delay = Duration(seconds: 3 + attempt * 3);
        _log.w('[Groq] 網路錯誤: ${e.message}，第 ${attempt + 1}/$totalAttempts 次重試');
        await Future<void>.delayed(delay);
        lastError = Exception('Groq 網路錯誤: ${e.message}');
      } on _GroqFatalException {
        // 不可重試：直接 rethrow，不做 status code 字串比對
        //（舊寫法 '0' 恆真，會把 400 也當 transient 空轉）。
        rethrow;
      } finally {
        // cached client stays alive; do not close
      }
    }

    // 所有重試用盡，記錄錯誤到檔案
    await _logError(
      audioPath: filePath,
      statusCode: lastStatus,
      responseBody: lastBody,
      error: lastError,
      keysTried: totalAttempts,
    );

    throw lastError ?? Exception('Groq 轉錄失敗：所有 key 和重試已用盡');
  }

  // ── 自動分段轉錄 ────────────────────────────────────
  /// 自動判斷檔案大小，超過 20MB 時以 ffmpeg 分段後逐段轉錄。
  /// [onChunk] 回報進度 (訊息, 0.0~1.0)。
  Future<String> transcribeAutoChunk(
    String filePath, {
    String model = 'whisper-large-v3-turbo',
    String? language,
    void Function(String message, double percent)? onChunk,
  }) async {
    final fileSize = await File(filePath).length();
    if (fileSize <= _maxFileSize) {
      // 小檔案：直接轉錄
      onChunk?.call('上傳音檔中…', 0.1);
      final text = await transcribe(filePath, model: model, language: language);
      onChunk?.call('轉錄完成', 1.0);
      return text;
    }

    // 大檔案：分段轉錄
    onChunk?.call('音檔過大，開始分段…', 0.05);
    final chunks = await _splitAudio(filePath);
    if (chunks.isEmpty) throw Exception('音檔分段失敗：無法產生任何分段');

    onChunk?.call('共 ${chunks.length} 段，4 並行轉錄中…', 0.1);

    // 4 並行轉錄
    final texts = List<String>.filled(chunks.length, '');
    int done = 0;

    Future<void> transcribeOne(int i) async {
      _log.i('  [chunk ${i + 1}/${chunks.length}] ${chunks[i]}');
      try {
        final text = await transcribe(chunks[i], model: model, language: language);
        if (text.trim().isNotEmpty) {
          texts[i] = text;
        }
      } catch (e) {
        _log.w('  [chunk ${i + 1}] 轉錄失敗: $e');
      }
      done++;
      final pct = 0.1 + (0.9 * (done / chunks.length));
      onChunk?.call('轉錄中 $done/${chunks.length} 段…', pct);
    }

    // 真 worker pool：固定 4 並發，共用 index queue。
    // 原本 strided batching 第一批就 ceil(n/4) 全開，
    // 60s sub-chunk 下可達數十個並發上傳 → 429 風暴 + 記憶體爆。
    const workers = 4;
    int next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= chunks.length) return;
        await transcribeOne(i);
      }
    }
    await Future.wait(List.generate(workers, (_) => worker()));

    // 清理暫存分段檔案 + temp 目錄（fallback 回傳原檔時 parent 不是
    // temp dir，用檔名特徵 guard，不可误删原目錄）。
    for (final c in chunks) {
      try { await File(c).delete(); } catch (_) {}
    }
    try {
      final d = File(chunks.first).parent;
      if (d.path.contains('groq_chunk_')) d.deleteSync(recursive: true);
    } catch (_) {}

    onChunk?.call('轉錄完成', 1.0);
    return texts.where((t) => t.isNotEmpty).join('\n');
  }

  // ── ffmpeg 分段邏輯 ─────────────────────────────────
  /// 取得 ffmpeg 路徑
  String get _ffmpeg => ConfigService.instance.config.resolvedFfmpegPath;

  /// 取得 ffprobe 路徑（嘗試 ffmpeg 同目錄下的 ffprobe，否則 fallback 到 ffmpeg）
  String get _ffprobe {
    final ffmpegDir = _ffmpeg;
    // 嘗試把 ffmpeg.exe 換成 ffprobe.exe
    if (ffmpegDir.toLowerCase().endsWith('ffmpeg.exe')) {
      return '${ffmpegDir.substring(0, ffmpegDir.length - 10)}ffprobe.exe';
    }
    return 'ffprobe';
  }

  /// 用 ffprobe 取得音檔秒數
  Future<double> _getDuration(String filePath) async {
    try {
      final result = await Process.run(_ffprobe, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      if (result.exitCode == 0) {
        return double.tryParse(result.stdout.toString().trim()) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// 以 ffmpeg 切割音檔為多個 FLAC 分段。
  /// 回傳分段檔案路徑列表。
  Future<List<String>> _splitAudio(String filePath) async {
    final duration = await _getDuration(filePath);
    if (duration <= 0) {
      _log.w('ffprobe 取得時長失敗，嘗試直接上傳整檔');
      return [filePath]; // fallback: 直接傳原檔
    }

    final baseName = File(filePath).uri.pathSegments.last;
    final prefix = baseName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final tempDir = Directory.systemTemp.createTempSync('groq_chunk_');

    final chunks = <String>[];

    for (int s = 0; s < duration.ceil(); s += _chunkDurationSec) {
      final outPath = '${tempDir.path}\\chunk_${prefix}_${chunks.length}.flac';
      final result = await Process.run(_ffmpeg, [
        '-y', '-i', filePath,
        '-ss', '$s',
        '-t', '$_chunkDurationSec',
        '-ar', '16000',
        '-ac', '1',
        '-c:a', 'flac',
        '-compression_level', '0',
        outPath,
      ]);

      if (result.exitCode != 0 || !await File(outPath).exists()) {
        _log.w('ffmpeg 分段失敗 (ss=$s): ${result.stderr}');
        continue;
      }

      final chunkSize = await File(outPath).length();

      // 如果分段仍 > 20MB，二次切為 60 秒段
      if (chunkSize > _maxFileSize) {
        _log.i('  分段 ${chunks.length} 仍 ${chunkSize ~/ 1024 ~/ 1024}MB，二次切分');
        try { await File(outPath).delete(); } catch (_) {}
        final subChunks = await _subSplit(filePath, s, _chunkDurationSec, prefix, tempDir.path);
        chunks.addAll(subChunks);
      } else {
        chunks.add(outPath);
      }
    }

    // 如果完全沒有分段（極短音檔），直接用原檔
    if (chunks.isEmpty) {
      try { tempDir.deleteSync(recursive: true); } catch (_) {}
      return [filePath];
    }

    return chunks;
  }

  /// 二次分段：將某段再切成 60 秒的小段
  Future<List<String>> _subSplit(
    String filePath, int startSec, int totalSec, String prefix, String tempDir,
  ) async {
    final subChunks = <String>[];
    for (int ss = 0; ss < totalSec; ss += _subChunkDurationSec) {
      final outPath = '$tempDir\\chunk_${prefix}_${subChunks.length}.flac';
      final result = await Process.run(_ffmpeg, [
        '-y', '-i', filePath,
        '-ss', '${startSec + ss}',
        '-t', '$_subChunkDurationSec',
        '-ar', '16000',
        '-ac', '1',
        '-c:a', 'flac',
        '-compression_level', '0',
        outPath,
      ]);

      if (result.exitCode == 0 && await File(outPath).exists()) {
        final size = await File(outPath).length();
        if (size > 0 && size <= _maxFileSize) {
          subChunks.add(outPath);
        } else if (size > _maxFileSize) {
          _log.w('  60s 分段仍過大 (${size ~/ 1024}KB)，跳過');
          try { await File(outPath).delete(); } catch (_) {}
        }
      }
    }
    return subChunks;
  }

  /// Chat completion（用於 RAG 問答）。
  Future<String> chat(List<Map<String, String>> messages, {String model = 'llama-3.1-8b-instant', int maxTokens = 2048}) async {
    if (_keys.isEmpty) throw Exception('未設定 Groq API Key');

    final totalAttempts = _keys.length + _maxRetries;
    Exception? lastError;
    String lastBody = '';
    int lastStatus = 0;

    for (int attempt = 0; attempt < totalAttempts; attempt++) {
      final key = _nextKey();
      http.Client? client;
      try {
        client = _createClient();
        final resp = await client.post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': messages,
            'max_tokens': maxTokens,
          }),
        ).timeout(const Duration(seconds: 120));

        lastBody = resp.body;
        lastStatus = resp.statusCode;

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          return data['choices'][0]['message']['content'] as String? ?? '';
        }

        if (_retryableStatuses.contains(resp.statusCode)) {
          final delay = Duration(seconds: 3 + attempt * 3);
          _log.w('[Groq chat] HTTP ${resp.statusCode}，第 ${attempt + 1}/$totalAttempts 次重試');
          await Future<void>.delayed(delay);
          lastError = Exception('Groq chat 失敗 ${resp.statusCode}: ${resp.body}');
          continue;
        }

        throw _GroqFatalException(resp.statusCode, resp.body);
      } on TimeoutException {
        final delay = Duration(seconds: 3 + attempt * 3);
        _log.w('[Groq chat] 逾時，第 ${attempt + 1}/$totalAttempts 次重試');
        await Future<void>.delayed(delay);
        lastError = Exception('Groq chat 逾時');
      } on SocketException catch (e) {
        final delay = Duration(seconds: 3 + attempt * 3);
        _log.w('[Groq chat] 網路錯誤: ${e.message}，第 ${attempt + 1}/$totalAttempts 次重試');
        await Future<void>.delayed(delay);
        lastError = Exception('Groq chat 網路錯誤: ${e.message}');
      } on _GroqFatalException {
        rethrow;
      } finally {
        // cached client stays alive; do not close
      }
    }

    // 所有重試用盡，記錄錯誤
    await _logError(
      audioPath: '[chat-completion]',
      statusCode: lastStatus,
      responseBody: lastBody,
      error: lastError,
      keysTried: totalAttempts,
    );

    throw lastError ?? Exception('Groq chat 失敗：所有 key 和重試已用盡');
  }
}
