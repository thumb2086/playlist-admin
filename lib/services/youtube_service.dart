import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:logger/logger.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// YouTube 串流服務：搜尋 + 取音訊 URL + 下載（全原生 Dart，零 Python 依賴）。
///
/// 用 `youtube_explode_dart` 直接與 YouTube 溝通，不需要 yt-dlp CLI。
class YoutubeService {
  YoutubeService._();
  static final instance = YoutubeService._();

  bool _closed = false;

  /// Create fresh instance per call to avoid stale connections.
  YoutubeExplode _fresh() => YoutubeExplode();

  // ── URL 解析 ──────────────────────────────────────────
  /// 從 YouTube URL 解析出 VideoId。
  /// 支援格式: youtube.com/watch?v=xxx, youtu.be/xxx, youtube.com/embed/xxx
  static VideoId? parseVideoId(String input) {
    final trimmed = input.trim();
    // 嘗試直接當作 video ID（11 字元）
    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed)) {
      return VideoId(trimmed);
    }
    // 嘗試從 URL 解析
    try {
      final uri = Uri.parse(trimmed);
      // youtu.be/xxx
      if (uri.host.contains('youtu.be')) {
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
        if (id.length == 11) return VideoId(id);
      }
      // youtube.com/watch?v=xxx
      if (uri.queryParameters.containsKey('v')) {
        final id = uri.queryParameters['v']!;
        if (id.length == 11) return VideoId(id);
      }
      // youtube.com/embed/xxx or youtube.com/v/xxx
      final pathSegments = uri.pathSegments;
      if (pathSegments.length >= 2) {
        final prefix = pathSegments[pathSegments.length - 2];
        if (prefix == 'embed' || prefix == 'v') {
          final id = pathSegments.last;
          if (id.length == 11) return VideoId(id);
        }
      }
    } catch (_) {}
    return null;
  }

  // ── 搜尋 ─────────────────────────────────────────────
  /// 搜尋 YouTube 並回傳前 N 個結果。
  Future<List<YoutubeSearchResult>> search(String query, {int limit = 5}) async {
    if (_closed) return [];
    final yt = _fresh();
    try {
      final searchList = await yt.search.search(query);
      final results = searchList.take(limit).map((v) => YoutubeSearchResult(
        videoId: v.id.value,
        title: v.title,
        author: v.author,
        duration: v.duration ?? Duration.zero,
        thumbnailUrl: v.thumbnails.highResUrl,
      )).toList();
      _log.i('YouTube 搜尋 "$query" → ${results.length} 筆結果');
      return results;
    } catch (e) {
      _log.e('YouTube 搜尋失敗: $e');
      return [];
    } finally {
      yt.close();
    }
  }

  /// 根據 videoId 取得最佳音訊串流 URL。
  /// 回傳可直接播放的 HTTP URL。
  Future<String?> getAudioUrl(String videoId) async {
    if (_closed) return null;
    final yt = _fresh();
    try {
      final manifest = await yt.videos.streams.getManifest(VideoId(videoId));
      final audioOnly = manifest.audioOnly.sortByBitrate();
      if (audioOnly.isEmpty) return null;
      final best = audioOnly.last;
      _log.i('YouTube 音訊: ${best.bitrate} (${best.container})');
      return best.url.toString();
    } catch (e) {
      _log.e('YouTube 取串流失敗: $e');
      return null;
    } finally {
      yt.close();
    }
  }

  /// 根據查詢一次搞定：搜尋 → 取最佳音訊 URL。
  /// 回傳 best match 的 URL 和元資料。自動重試 1 次。
  Future<YoutubeStreamResult?> resolveStream(String query) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final results = await search(query, limit: 5)
            .timeout(const Duration(seconds: 20), onTimeout: () => []);
        if (results.isEmpty) continue;

        final best = results.first;
        final url = await getAudioUrl(best.videoId)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        if (url == null) continue;

        return YoutubeStreamResult(
          videoId: best.videoId,
          title: best.title,
          author: best.author,
          duration: best.duration,
          thumbnailUrl: best.thumbnailUrl,
          audioUrl: url,
        );
      } catch (e) {
        _log.e('YouTube resolve 失敗 (attempt ${attempt + 1}): $e');
        if (attempt == 0) await Future.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  // ── URL 下載（取代 Python bridge download-youtube）──
  /// 從 YouTube URL 下載音訊並轉碼為指定格式。
  /// [url] - YouTube URL 或 video ID
  /// [outputPath] - 輸出檔案完整路徑（含副檔名）
  /// [format] - 目標格式（預設 mp3）
  /// [onProgress] - 進度回調 (0.0~1.0)
  Future<String?> downloadFromUrl(
    String url, {
    required String outputPath,
    String format = 'mp3',
    void Function(double progress)? onProgress,
  }) async {
    final videoId = parseVideoId(url);
    if (videoId == null) {
      _log.e('無法解析 YouTube URL: $url');
      return null;
    }

    // 取得音訊串流 URL
    onProgress?.call(0.1);
    final audioUrl = await getAudioUrl(videoId.value);
    if (audioUrl == null) {
      _log.e('無法取得音訊串流: $url');
      return null;
    }

    // 用 YoutubeExplode 下載 + 本地 ffmpeg 轉碼
    onProgress?.call(0.1);
    final result = await downloadAudio(
      audioUrl,
      outputPath: outputPath,
      format: format,
      onProgress: onProgress,
      videoId: videoId.value,
    );

    return result;
  }

  // ── 搜尋下載（取代 Python bridge download-song）─────
  /// 搜尋 YouTube 並下載最佳匹配的音訊。
  /// [query] - 搜尋字串（如 "周杰倫 晴天"）
  /// [outputPath] - 輸出檔案完整路徑（含副檔名）
  /// [format] - 目標格式（預設 mp3）
  Future<String?> downloadBySearch(
    String query, {
    required String outputPath,
    String format = 'mp3',
    void Function(double progress)? onProgress,
  }) async {
    // 搜尋 + 取得音訊 URL
    onProgress?.call(0.05);
    final result = await resolveStream(query);
    if (result == null) {
      _log.e('搜尋下載失敗: $query');
      return null;
    }

    // 用 YoutubeExplode 下載 + 本地 ffmpeg 轉碼
    onProgress?.call(0.1);
    final savedPath = await downloadAudio(
      result.audioUrl,
      outputPath: outputPath,
      format: format,
      onProgress: onProgress,
      videoId: result.videoId,
    );

    if (savedPath != null) {
      _log.i('搜尋下載完成: ${result.title} → $savedPath');
    }
    return savedPath;
  }

  // ── 搜尋 + 下載一步到位（取代 resolveStream + downloadAudio） ──
  /// 用 yt-dlp 的 ytsearch: 一次搞定搜尋+下載，避免雙重 HTTP 被 YouTube bot 偵測。
  Future<String?> searchAndDownload(
    String query, {
    required String outputPath,
    String format = 'mp3',
    void Function(String? title)? onTitle,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);
    final dlDir = Directory.systemTemp.createTempSync('yt_dl_');
    final dlTemp = '${dlDir.path}\\audio';

    final baseArgs = [
      '-x',
      '--audio-format', format,
      '-f', 'ba/b',
      '--no-playlist',
      '--no-overwrites',
      '--no-check-certificates',
      '--extractor-args', 'youtube:player_client=mweb',
      '-o', '$dlTemp.%(ext)s',
      '--retries', '3',
      '--fragment-retries', '10',
      '--socket-timeout', '60',
      '--skip-unavailable-fragments',
      '--ignore-errors',
      '--add-header', 'User-Agent:Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      '--add-header', 'Accept-Language:zh-TW,zh;q=0.9,en;q=0.5',
      '--print', 'after_move:filepath',  // 輸出最終檔案路徑
    ];

    // 加入餅乾（如果有的話）
    final searchCookies = _findCookies();
    if (searchCookies != null) {
      baseArgs.addAll(['--cookies', searchCookies]);
    }

    try {
      // 用 ytsearch1: 讓 yt-dlp 搜尋+下載一步到位
      final proc = await _startYtDlp([...baseArgs, 'ytsearch1:$query']);

      String lastErr = '';
      String? finalPath;
      double lastPct = 0;
      proc.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        // --print after_move:filepath 會輸出最終路徑
        if (line.contains('\\') || line.contains('/')) {
          finalPath = line.trim();
        }
      });
      proc.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        // 累積完整 stderr：只留最後一行會洗掉關鍵錯誤（如 requested format）。
        lastErr = '$lastErr\n$line';
        if (lastErr.length > 4000) lastErr = lastErr.substring(lastErr.length - 4000);
        // 解析下載百分比：[download]  45.2% of ... → onProgress(0.1~0.9)
        final pctMatch = RegExp(r'\[download\]\s+([\d.]+)%').firstMatch(line);
        if (pctMatch != null) {
          final pct = ((double.tryParse(pctMatch.group(1)!) ?? 0).clamp(0.0, 100.0)).toDouble();
          if (pct >= lastPct) {
            lastPct = pct;
            onProgress?.call(0.1 + pct / 100 * 0.8);
          }
        }
        // 從 stderr 解析標題
        if (line.contains('[download] Destination:')) {
          final titleMatch = RegExp(r'Destination: .+\\(.+)$').firstMatch(line);
          if (titleMatch != null) {
            onTitle?.call(titleMatch.group(1)?.replaceAll(RegExp(r'\.\w+$'), ''));
          }
        }
      });

      final code = await proc.exitCode.timeout(
        const Duration(seconds: 180),
        onTimeout: () { proc.kill(); return -1; },
      );

      onProgress?.call(0.9);

      if (code != 0) {
        _log.w('yt-dlp 搜尋下載失敗 (exit $code): $lastErr');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      // 找到輸出檔案
      File? found;
      if (finalPath != null && await File(finalPath!).exists()) {
        found = File(finalPath!);
      } else {
        // fallback: 掃描 temp 目錄
        await for (final f in dlDir.list()) {
          if (f is File && !f.path.endsWith('.part') && !f.path.endsWith('.temp')) {
            found = f;
            break;
          }
        }
      }

      if (found == null || !await found.exists()) {
        _log.w('yt-dlp 找不到輸出檔案');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      final fileSize = await found.length();
      if (fileSize < 1024) {
        _log.w('yt-dlp 輸出檔案太小 (${fileSize}B)');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      final outDir = Directory(File(outputPath).parent.path);
      if (!await outDir.exists()) await outDir.create(recursive: true);
      await _moveFile(found, outputPath);

      onProgress?.call(1.0);
      _log.i('yt-dlp 下載完成: ${outputPath.split('\\').last} (${fileSize ~/ 1024}KB)');
      return outputPath;
    } catch (e) {
      _log.e('yt-dlp 異常: $e');
      return null;
    } finally {
      try { dlDir.deleteSync(recursive: true); } catch (_) {}
    }
  }

  /// 跨磁碟 rename 會拋 FileSystemException（systemTemp vs 音樂庫不同碟）：
  /// 失敗改 copy+delete，下載成功不再回報 null。
  static Future<void> _moveFile(File src, String dest) async {
    if (await File(dest).exists()) await File(dest).delete();
    try {
      await src.rename(dest);
    } on FileSystemException {
      await src.copy(dest);
      try { await src.delete(); } catch (_) {}
    }
  }

  /// Windows 上 yt-dlp 可能是 .bat shim（CreateProcess 不跑腳本）：
  /// 先 runInShell:false（歌名含 & | ; 不會被 cmd 切斷/注入），
  /// 啟動失敗才 true 重試一次。
  static Future<Process> _startYtDlp(List<String> args) async {
    try {
      return await Process.start('yt-dlp', args, runInShell: false);
    } catch (_) {
      _log.w('yt-dlp 直接啟動失敗，改用 shell 重試');
      return await Process.start('yt-dlp', args, runInShell: true);
    }
  }

  // ── 底層下載 ─────────────────────────────────────────
  /// 搜尋餅乾檔案。
  static String? _cookiesPath;
  static String? _findCookies() {
    if (_cookiesPath != null) return _cookiesPath;
    final home = Platform.environment['USERPROFILE'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';
    final paths = [
      '$home\\Desktop\\yt_cookies.txt',
      '$home\\Documents\\yt_cookies.txt',
      if (appData.isNotEmpty) '$appData\\playlist-admin\\yt_cookies.txt',
    ];
    for (final p in paths) {
      if (File(p).existsSync()) { _cookiesPath = p; return p; }
    }
    return null;
  }

  /// 用 yt-dlp CLI 下載 YouTube 音訊。
  /// 使用 temp 目錄避免路徑問題，完成後移到 outputPath。
  Future<String?> downloadAudio(
    String audioUrl, {
    required String outputPath,
    String format = 'mp3',
    void Function(double progress)? onProgress,
    String? videoId,
  }) async {
    final ytUrl = videoId != null ? 'https://www.youtube.com/watch?v=$videoId' : audioUrl;
    onProgress?.call(0.1);

    // 用 temp 目錄避免路徑/副檔名問題
    final dlDir = Directory.systemTemp.createTempSync('yt_dl_');
    final dlTemp = '${dlDir.path}\\audio';

    // mweb player client: 目前唯一可用的下載路徑（android_vr 被 403, web 只有圖片）。
    final baseArgs = [
      '-x',
      '--audio-format', format,
      '-f', 'ba/b',
      '--no-playlist',
      '--no-overwrites',
      '--no-check-certificates',
      '--extractor-args', 'youtube:player_client=mweb',
      '-o', '$dlTemp.%(ext)s',
      '--retries', '3',
      '--fragment-retries', '10',
      '--socket-timeout', '60',
      '--skip-unavailable-fragments',
      '--ignore-errors',
      '--add-header', 'User-Agent:Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      '--add-header', 'Accept-Language:zh-TW,zh;q=0.9,en;q=0.5',
    ];

    // 加入餅乾（如果有的話）
    final cookies = _findCookies();
    if (cookies != null) {
      baseArgs.addAll(['--cookies', cookies]);
    }

    try {
      // 第一輪：標準下載（_startYtDlp 內優先無 shell，防 URL 的 & 被切斷）
      var proc = await _startYtDlp([...baseArgs, ytUrl]);
      var errBuf = StringBuffer();
      proc.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        errBuf.writeln(line);
        if (errBuf.length > 4000) {
          errBuf = StringBuffer(errBuf.toString().substring(errBuf.length - 4000));
        }
      });
      var code = await proc.exitCode.timeout(
        const Duration(seconds: 180),
        onTimeout: () { proc.kill(); return -1; },
      );

      // 第一輪失敗 → 降級 fallback（只換 -f，其餘設定含 cookies/headers 沿用，
      // 否則降級反而更容易被 bot 擋）。
      if (code != 0 && errBuf.toString().contains('requested format is not available')) {
        _log.w('yt-dlp 格式不可用，嘗試 fallback');
        final fallbackArgs = [...baseArgs];
        final fIdx = fallbackArgs.indexOf('-f');
        fallbackArgs[fIdx + 1] = 'worstvideo[ext=mp4]+worstaudio/best';
        proc = await _startYtDlp([...fallbackArgs, ytUrl]);
        errBuf = StringBuffer();
        proc.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
          errBuf.writeln(line);
          if (errBuf.length > 4000) {
            errBuf = StringBuffer(errBuf.toString().substring(errBuf.length - 4000));
          }
        });
        code = await proc.exitCode.timeout(
          const Duration(seconds: 180),
          onTimeout: () { proc.kill(); return -1; },
        );
      }

      onProgress?.call(0.9);

      if (code != 0) {
        final lastErr = errBuf.toString();
        _log.w('yt-dlp 失敗 (exit $code): ${lastErr.length > 300 ? lastErr.substring(lastErr.length - 300) : lastErr}');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      // 找到 yt-dlp 輸出的檔案（副檔名可能不同）
      File? found;
      await for (final f in dlDir.list()) {
        if (f is File && !f.path.endsWith('.part') && !f.path.endsWith('.temp')) {
          found = f;
          break;
        }
      }

      if (found == null || !await found.exists()) {
        _log.w('yt-dlp 找不到輸出檔案');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      final fileSize = await found.length();
      if (fileSize < 1024) {
        _log.w('yt-dlp 輸出檔案太小 (${fileSize}B)，可能下載失敗');
        dlDir.deleteSync(recursive: true);
        return null;
      }

      // 確保目標目錄存在
      final outDir = Directory(File(outputPath).parent.path);
      if (!await outDir.exists()) await outDir.create(recursive: true);

      // 移動到目標路徑（跨磁碟自動降級 copy+delete）
      await _moveFile(found, outputPath);

      onProgress?.call(1.0);
      _log.i('yt-dlp 下載完成: ${outputPath.split('\\').last} (${fileSize ~/ 1024}KB)');
      return outputPath;
    } catch (e) {
      _log.e('yt-dlp 異常: $e');
      return null;
    } finally {
      try { dlDir.deleteSync(recursive: true); } catch (_) {}
    }
  }

  void close() {
    _closed = true;
  }
}

/// 搜尋結果。
class YoutubeSearchResult {
  final String videoId;
  final String title;
  final String author;
  final Duration duration;
  final String thumbnailUrl;

  const YoutubeSearchResult({
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
  });
}

/// 解析後的串流結果（含可播放 URL）。
class YoutubeStreamResult extends YoutubeSearchResult {
  final String audioUrl;

  const YoutubeStreamResult({
    required super.videoId,
    required super.title,
    required super.author,
    required super.duration,
    required super.thumbnailUrl,
    required this.audioUrl,
  });
}
