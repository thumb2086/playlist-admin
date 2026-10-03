import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/podcast_episode.dart';
import '../models/podcast_search_result.dart';
import 'config_service.dart';
import 'youtube_service.dart';

enum PodcastSubtitleResult { found, notFound, failed }

/// 取消訊號：呼叫方（如下載頁取消鈕）透過 isCancelled 回報，
/// 串流迴圈內拋出即中斷，殘檔由既有 catch 清理後 rethrow。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class PodcastService {
  static PodcastService? _instance;
  static PodcastService get instance => _instance ??= PodcastService._();
  PodcastService._();

  String _podcastDir(String? podcastName) {
    final cfg = ConfigService.instance.config;
    final base = cfg.podcastsPath;
    if (base.isEmpty) return '';
    final sub = podcastName != null && podcastName.isNotEmpty
        ? podcastName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        : '';
    final path = sub.isNotEmpty ? '$base\\$sub' : base;
    Directory(path).createSync(recursive: true);
    return path;
  }

  String get _downloadPath => _podcastDir(null);

  static String normalizeFileName(String title) {
    return title
        .replaceAll(RegExp(r'\s*\[[\w-]{11}\]'), '')
        .replaceAll(RegExp(r'[<>:"/\\|?*&]'), '_')
        .trim();
  }

  /// Fetch RSS feed and parse episodes natively (no Python).
  /// 30s timeout：http 預設無超時，連線僵住會連帶卡死整批 Future.wait，
  /// 讓暫停/取消按鈕看起來像沒反應。
  Future<({String title, List<PodcastEpisode> episodes})> fetchEpisodes(
      String rssUrl) async {
    if (isYtChannelUrl(rssUrl)) {
      throw Exception(
          '這是 YouTube 頻道訂閱（RAG 逐字稿用），沒有 RSS 集數；到 Pipeline 跑 Podcast 流程');
    }
    final resp = await http.get(Uri.parse(rssUrl), headers: {
      'User-Agent': 'playlist-admin/2.0',
    }).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('RSS fetch failed (${resp.statusCode})');
    }
    // Force UTF-8 decode: http.Response.body may not decode correctly
    // when Content-Type lacks charset (e.g. SoundOn feeds → Latin-1).
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final doc = XmlDocument.parse(body);
    final channel = doc.findAllElements('channel').firstOrNull;
    if (channel == null) throw Exception('No <channel> in RSS');
    final title = channel.findAllElements('title').firstOrNull?.innerText ?? '';
    final episodes = <PodcastEpisode>[];
    for (final item in channel.findAllElements('item')) {
      final epTitle = item.findAllElements('title').firstOrNull?.innerText ?? '';
      final description = item.findAllElements('description').firstOrNull?.innerText ?? '';
      final pubDate = item.findAllElements('pubDate').firstOrNull?.innerText ?? '';
      // Duration from itunes:duration
      const itunesNs = 'http://www.itunes.com/dtds/podcast-1.0.dtd';
      final durationEl = item.findAllElements('duration', namespace: itunesNs).firstOrNull
          ?? item.findAllElements('{http://www.itunes.com/dtds/podcast-1.0.dtd}duration').firstOrNull;
      final durationStr = durationEl?.innerText ?? '';
      // Audio URL from enclosure.
      final enclosure = item.findAllElements('enclosure').firstOrNull;
      final audioUrl = enclosure?.getAttribute('url') ?? '';
      episodes.add(PodcastEpisode(
        title: epTitle,
        audioUrl: audioUrl,
        description: description,
        pubDate: pubDate,
        duration: durationStr,
      ));
    }
    return (title: title, episodes: episodes);
  }

  /// Get audio URL for a specific episode index from RSS.
  Future<String?> getAudioUrl(String rssUrl, int index) async {
    http.Response resp;
    try {
      resp = await http.get(Uri.parse(rssUrl), headers: {
        'User-Agent': 'playlist-admin/2.0',
      }).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return null;
    }
    if (resp.statusCode != 200) return null;
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final doc = XmlDocument.parse(body);
    final items = doc.findAllElements('item').toList();
    if (index < 0 || index >= items.length) return null;
    final item = items[index];
    // Check enclosure first, then itunes:audio
    final enclosure = item.findAllElements('enclosure').firstOrNull;
    if (enclosure != null) {
      return enclosure.getAttribute('url');
    }
    final audio = item.findAllElements('{http://www.itunes.com/dtds/podcast-1.0.dtd}audio').firstOrNull;
    return audio?.getAttribute('href');
  }

  bool isEpisodeDownloaded(String title, String audioUrl, {String? podcastName}) {
    final ext = _guessExtension(audioUrl);
    final name = normalizeFileName(title);
    final podDir = podcastName != null ? _podcastDir(podcastName) : _downloadPath;
    if (File('$podDir\\$name.$ext').existsSync()) return true;
    final titleEp = RegExp(r'EP(\d+)', caseSensitive: false).firstMatch(title);
    if (titleEp == null) return false;
    final epNumInt = int.tryParse(titleEp.group(1)!);
    if (epNumInt == null) return false;
    final searchDir = Directory(podDir);
    if (!searchDir.existsSync()) return false;
    try {
      return searchDir.listSync().any((f) {
        if (f is! File) return false;
        final fname = f.uri.pathSegments.last;
        if (fname.startsWith('\u3010\u8a66\u807d\u3011') || fname.startsWith('\u3010')) return false;
        final fileEp = RegExp(r'EP(\d+)', caseSensitive: false).firstMatch(fname);
        if (fileEp == null) return false;
        return int.tryParse(fileEp.group(1)!) == epNumInt;
      });
    } catch (_) {}
    return false;
  }

  String episodeOutputPath(String title, String audioUrl) {
    final safeName = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final ext = _guessExtension(audioUrl);
    return '$_downloadPath\\$safeName.$ext';
  }

  /// Download episode audio natively (HTTP streaming, no Python).
  ///
  /// [knownTitle]/[knownAudioUrl] 由呼叫方（已抓過 RSS）直接傳入，
  /// 避免同一 feed 為每集重抓重解析 3 次。沒傳時才 fallback 重抓。
  Future<bool> downloadEpisode(
    String rssUrl,
    int index,
    void Function(double progress) onProgress, {
    String? podcastName,
    String? knownTitle,
    String? knownAudioUrl,
    bool Function()? isCancelled,
  }) async {
    String? audioUrl = (knownAudioUrl != null && knownAudioUrl.isNotEmpty)
        ? knownAudioUrl
        : await getAudioUrl(rssUrl, index);
    if (audioUrl == null || audioUrl.isEmpty) throw Exception('No audio URL found');

    String title;
    if (knownTitle != null && knownTitle.isNotEmpty) {
      title = knownTitle;
    } else {
      // Fallback: re-fetch RSS for the title.
      final resp2 = await http.get(Uri.parse(rssUrl), headers: {
        'User-Agent': 'playlist-admin/2.0',
      }).timeout(const Duration(seconds: 30));
      final body2 = utf8.decode(resp2.bodyBytes, allowMalformed: true);
      final doc = XmlDocument.parse(body2);
      final items = doc.findAllElements('item').toList();
      title = index < items.length
          ? items[index].findAllElements('title').firstOrNull?.innerText ?? 'episode_$index'
          : 'episode_$index';
    }

    final name = normalizeFileName(title);
    final ext = _guessExtension(audioUrl);
    final outDir = _podcastDir(podcastName);
    final outputPath = '$outDir\\$name.$ext';
    if (await File(outputPath).exists()) {
      onProgress(1.0);
      return false;
    }

    // Native HTTP download (timeouts everywhere: stalled connection must not
    // hang the batch forever, otherwise pause/cancel looks dead).
    final client = http.Client();
    IOSink? sink;
    try {
      if (isCancelled?.call() ?? false) throw const DownloadCancelled();
      final request = http.Request('GET', Uri.parse(audioUrl));
      final response = await client.send(request).timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw Exception('Download failed (${response.statusCode})');
      }
      final totalBytes = response.contentLength ?? 0;
      int received = 0;
      int sinceFlush = 0;
      sink = File(outputPath).openWrite();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
        onTimeout: (sinkCtrl) => sinkCtrl.addError(TimeoutException('download stalled')),
      )) {
        if (isCancelled?.call() ?? false) throw const DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        sinceFlush += chunk.length;
        // 背壓：每 ~5MB flush 一次，避免百 MB 檔全緩衝進記憶體。
        if (sinceFlush >= 5 * 1024 * 1024) {
          await sink.flush();
          sinceFlush = 0;
        }
        if (totalBytes > 0) onProgress(received / totalBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      try { if (await File(outputPath).exists()) await File(outputPath).delete(); } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
    // 0-byte/截斷檔不可回傳 true：否則下次 File.exists 跳過下載，永不重試。
    final savedSize = await File(outputPath).length().catchError((_) => 0);
    if (savedSize < 1024) {
      try { await File(outputPath).delete(); } catch (_) {}
      throw Exception('下載檔案過小 (${savedSize}B)，視為失敗');
    }
    onProgress(1.0);
    return true;
  }

  /// Download subtitles via YoutubeService (native).
  Future<PodcastSubtitleResult> downloadSubtitles(
    String episodeTitle,
    String podcastName, {
    required void Function(String log) onLog,
    bool Function()? isCancelled,
  }) async {
    final outDir = _podcastDir(podcastName);
    final safeName = normalizeFileName(episodeTitle);
    final outputPath = '$outDir\\$safeName.mp3';

    if (await File(outputPath.replaceAll('.mp3', '.srt')).exists()) {
      onLog('已有字幕，跳過');
      return PodcastSubtitleResult.found;
    }

    // Use yt-dlp CLI for subtitles (youtube_explode doesn't support auto-captions well).
    final query = '$episodeTitle $podcastName';
    try {
      final proc = await Process.start(
        'python',
        ['tools\\flutter_download_bridge.py', 'youtube-subs', query, outputPath, podcastName],
        runInShell: false, // query 可能含 &（集名）：不可經 cmd
        workingDirectory: ConfigService.instance.config.basePath,
        environment: {'PYTHONIOENCODING': 'utf-8'},
      );
      var result = PodcastSubtitleResult.failed;
      final outDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
        if (line.trim().isEmpty) return;
        try {
          final json = jsonDecode(line.trim()) as Map<String, dynamic>;
          final type = json['type'] as String?;
          if (type == 'log') {
            onLog(json['message'] as String? ?? '');
          } else if (type == 'error') { onLog('${json['message']}'); result = PodcastSubtitleResult.failed; }
          else if (type == 'not_found') { onLog('${json['message']}'); result = PodcastSubtitleResult.notFound; }
          else if (type == 'complete') { onLog('字幕下載完成'); result = PodcastSubtitleResult.found; }
        } catch (_) { onLog(line); }
      });
      final completer = Completer<int>();
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (isCancelled?.call() == true && !completer.isCompleted) {
          if (Platform.isWindows) {
            Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
          } else {
            proc.kill(ProcessSignal.sigterm);
          }
          completer.complete(-1);
        }
      });
      var timeoutDone = false;
      // ignore: unused_local_variable
      final _ = Future.delayed(const Duration(seconds: 180), () {
        if (!completer.isCompleted && !timeoutDone) {
          // Windows: runInShell spawns cmd.exe; must kill process tree
          if (Platform.isWindows) {
            Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
          } else {
            proc.kill(ProcessSignal.sigterm);
          }
          onLog('字幕下載逾時 (180s)，下次重試');
          completer.complete(-1);
        }
      });
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });
      await completer.future;
      timer.cancel();
      timeoutDone = true;
      try {
        await outDone.timeout(const Duration(seconds: 10));
      } catch (_) {}
      return result;
    } catch (e) {
      onLog('字幕下載失敗: $e');
      return PodcastSubtitleResult.failed;
    }
  }

  String _guessExtension(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    if (path.endsWith('.mp3')) return 'mp3';
    if (path.endsWith('.m4a')) return 'm4a';
    if (path.endsWith('.wav')) return 'wav';
    if (path.endsWith('.ogg')) return 'ogg';
    if (path.endsWith('.flac')) return 'flac';
    if (path.endsWith('.aac')) return 'aac';
    return 'mp3';
  }

  String get downloadPath => _downloadPath;
  String podcastDir(String? podcastName) => _podcastDir(podcastName);
  static String relativePodcastPath = 'podcasts';

  // ═══════════════════════════════════════════════════════════
  //  YouTube 頻道（RAG 逐字稿）：貼頻道網址 → 抓字幕 → 進 RAG
  // ═══════════════════════════════════════════════════════════

  /// 任何 YouTube 網址（@頻道 / channel / c / 單支影片 / 播放清單）。
  /// RSS feed 不會是 youtube.com → 無誤判。
  static bool isYtChannelUrl(String url) =>
      RegExp(r'(youtube\.com|youtu\.be)/', caseSensitive: false).hasMatch(url);

  List<String> _ytCookieArgs() {
    final env = Platform.environment['YT_COOKIES'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) {
      return ['--cookies', env];
    }
    final ck = YoutubeService.cookiesPathForDiag;
    return ck != null ? ['--cookies', ck] : const [];
  }

  /// yt-dlp 執行器：收集 stdout/stderr，逾時或取消時殺整棵程序樹。
  /// 不可 runInShell（參數含 & 等字元）。null = 逾時/取消/啟動失敗。
  Future<({int code, String out, String err})?> _runYtDlp(
    List<String> args, {
    required Duration timeout,
    bool Function()? isCancelled,
  }) async {
    Process proc;
    try {
      proc = await Process.start('yt-dlp', args, runInShell: false,
          environment: {'PYTHONIOENCODING': 'utf-8'});
    } catch (_) {
      return null;
    }
    final out = StringBuffer();
    final err = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen(out.write);
    proc.stderr.transform(utf8.decoder).listen(err.write);
    final completer = Completer<int>();
    void kill() {
      if (Platform.isWindows) {
        Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill(ProcessSignal.sigterm);
      }
    }

    final cancelTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isCancelled?.call() == true && !completer.isCompleted) {
        kill();
        completer.complete(-1);
      }
    });
    final timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        kill();
        completer.complete(-1);
      }
    });
    proc.exitCode.then((c) {
      if (!completer.isCompleted) completer.complete(c);
    });
    final code = await completer.future;
    cancelTimer.cancel();
    timeoutTimer.cancel();
    // 殺程序後讓 stdout/stderr 尾巴 flush 完再回。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return (code: code, out: out.toString(), err: err.toString());
  }

  /// 解析頻道標題（當訂閱名稱）。失敗退回 @handle / URL 尾段。
  Future<String?> resolveChannelTitle(String url) async {
    final r = await _runYtDlp(
        ['--playlist-items', '1', '--skip-download', '--print', '%(channel)s',
         ..._ytCookieArgs(), url],
        timeout: const Duration(seconds: 60));
    for (final l in (r?.out ?? '').split('\n').map((l) => l.trim())) {
      if (l.isNotEmpty && l != 'NA' && !l.startsWith('ERROR')) return l;
    }
    final m = RegExp(r'@([\w.\-]+)').firstMatch(url);
    if (m != null) return m.group(1);
    final seg = url.split('?').first.split('/').last;
    return seg.isEmpty ? null : seg;
  }

  /// 解析 `%(id)s\t%(title)s` 輸出（純函式，可測）。
  static List<({String id, String title})> parseFlatListOutput(String out) {
    final rows = <({String id, String title})>[];
    for (final line in out.split('\n')) {
      final i = line.indexOf('\t');
      if (i <= 0) continue;
      final id = line.substring(0, i);
      if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) continue;
      rows.add((id: id, title: line.substring(i + 1).trim()));
    }
    return rows;
  }

  /// 列頻道影片（flat 模式，快）。null = 失敗/取消。
  Future<List<({String id, String title})>?> listChannelVideos(
      String url, {bool Function()? isCancelled}) async {
    final r = await _runYtDlp(
        ['--flat-playlist', '--print', '%(id)s\t%(title)s',
         ..._ytCookieArgs(), url],
        timeout: const Duration(minutes: 3),
        isCancelled: isCancelled);
    if (r == null || r.code != 0) return null;
    return parseFlatListOutput(r.out);
  }

  /// 以影片 URL 直抓字幕（人工+自動，中/英/日）→ outDir\<safeName>[.lang].srt。
  Future<PodcastSubtitleResult> fetchYtSubtitlesByUrl(
      String videoUrl, String outDir, String safeName,
      {bool Function()? isCancelled, void Function(String)? onLog}) async {
    await Directory(outDir).create(recursive: true);
    final r = await _runYtDlp([
      '--skip-download',
      '--write-subs', '--write-auto-subs',
      '--sub-langs', 'zh-Hant,zh-Hans,zh-TW,zh,en,ja',
      '--sub-format', 'best', '--convert-subs', 'srt',
      '-o', '$outDir\\$safeName',
      ..._ytCookieArgs(),
      videoUrl,
    ], timeout: const Duration(minutes: 3), isCancelled: isCancelled);
    if (r == null) return PodcastSubtitleResult.failed; // 逾時/取消 → 可重試
    if (r.code == 0) {
      // exit 0 但沒檔案 = 真的沒字幕（yt-dlp 只給 warning）。
      final prefix = '$safeName.';
      try {
        for (final x in Directory(outDir).listSync()) {
          if (x is File) {
            final fn = x.uri.pathSegments.last;
            if (fn.startsWith(prefix) && fn.toLowerCase().endsWith('.srt')) {
              return PodcastSubtitleResult.found;
            }
          }
        }
      } catch (_) {}
      return PodcastSubtitleResult.notFound;
    }
    // 失敗原因回報給管線 log（429/網路/影片問題一眼可辨）。
    final errTail = r.err.split('\n').where((l) => l.trim().isNotEmpty).take(3).join(' | ');
    if (errTail.isNotEmpty) onLog?.call('yt-dlp: $errTail');
    final e = r.err.toLowerCase();
    if (e.contains('no subtitles') || e.contains('could not be found') ||
        e.contains('unavailable') || e.contains('private video')) {
      return PodcastSubtitleResult.notFound;
    }
    return PodcastSubtitleResult.failed;
  }

  Future<List<PodcastSearchResult>> searchPodcasts(String query) async {
    final url = Uri.parse(
        'https://itunes.apple.com/search?term=${Uri.encodeQueryComponent(query)}&media=podcast&limit=20');
    final resp = await http.get(url, headers: {'User-Agent': 'playlist-admin/2.0'});
    if (resp.statusCode != 200) throw Exception('搜尋失敗 (${resp.statusCode})');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = data['results'] as List<dynamic>? ?? [];
    return results
        .map((r) => PodcastSearchResult.fromAppleJson(r as Map<String, dynamic>))
        .where((r) => r.feedUrl.isNotEmpty)
        .toList();
  }
}
