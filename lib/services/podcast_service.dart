import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/podcast_episode.dart';
import '../models/podcast_search_result.dart';
import 'config_service.dart';

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
        runInShell: true,
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
      // 等待 yt-dlp 完成，每秒檢查 cancel
      final completer = Completer<int>();
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (isCancelled?.call() == true && !completer.isCompleted) {
          try { proc.kill(); } catch (_) {}
          completer.complete(-1);
        }
      });
      Future.delayed(const Duration(seconds: 180), () {
        if (!completer.isCompleted) {
          try { proc.kill(); } catch (_) {}
          onLog('字幕下載逾時 (180s)，下次重試');
          completer.complete(-1);
        }
      });
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });
      await completer.future;
      timer.cancel();
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
