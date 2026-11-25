import 'dart:io';
import 'package:http/http.dart' as http;

import 'config_service.dart';

/// 下載網路用量估算（在真的下載之前先給數字）。
///
/// 為什麼需要：pipeline 一跑就是幾百 MB 起跳，使用者卻要等下載完才知道用了多少。
/// 這裡在「執行前」就給出預估，並在執行中累計實際位元組數。
///
/// 估算方式（刻意保守、可解釋）：
///   - 音樂：缺首歌 × 平均每首大小（預設 8 MB，可視為 320 kbps 的 3.5 分鐘）
///   - Podcast：RSS enclosure 有 length 就用真值；沒有就 每分鐘 2 MB
class TrafficEstimator {
  TrafficEstimator._();

  /// 平均每首歌位元組（320 kbps ≈ 40 KB/s；8 MB ≈ 3.3 分鐘）。
  static const int defaultMusicBytesPerTrack = 8 * 1024 * 1024;

  /// 沒有 enclosure 長度時，podcast 每分鐘的估計位元組。
  static const int podcastBytesPerMinute = 2 * 1024 * 1024;

  static String fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 磁碟剩餘空間（bytes）；取不到回 -1。
  /// 用 PowerShell Get-PSDrive：`dir` 的 "bytes free" 在中文版 Windows 是
  /// 「剩餘的位元組」，字串比對永遠抓不到（實測回 -1）。
  static Future<int> freeDiskBytes(String path) async {
    try {
      String drive;
      if (Platform.isWindows) {
        final m = RegExp(r'^([A-Za-z]):').firstMatch(path);
        if (m == null) return -1;
        drive = m.group(1)!;
      } else {
        return -1;
      }
      final r = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            '(Get-PSDrive -Name $drive).Free',
          ],
          runInShell: false);
      if (r.exitCode != 0) return -1;
      final v = int.tryParse(r.stdout.trim());
      return v != null && v > 0 ? v : -1;
    } catch (_) {
      return -1;
    }
  }

  /// 音樂：回 (缺幾首, 估計位元組)。
  static Future<({int missing, int bytes})> estimateMusic({int? avgBytesPerTrack}) async {
    final cfg = ConfigService.instance.config;
    final avg = avgBytesPerTrack ?? defaultMusicBytesPerTrack;

    final stems = <String>{};
    Future<void> scan(Directory d) async {
      if (!await d.exists()) return;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final low = e.path.toLowerCase();
          if (low.endsWith('.mp3') || low.endsWith('.flac')) {
            stems.add(_norm(File(e.path).uri.pathSegments.last));
          }
        }
      }
    }

    await scan(Directory(cfg.libraryPath));
    // 有些安裝把音樂放在 basePath/mp3|m4a|flac（library_page 也是這樣掃）
    final base = Directory(cfg.basePath);
    if (await base.exists() &&
        base.path.toLowerCase() != cfg.libraryPath.toLowerCase()) {
      for (final sub in ['mp3', 'm4a', 'flac']) {
        await scan(Directory('${cfg.basePath}${Platform.pathSeparator}$sub'));
      }
    }

    var missing = 0;
    final plDir = Directory(cfg.playlistsPath);
    if (await plDir.exists()) {
      await for (final e in plDir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.m3u8')) {
          final lines = await e.readAsLines();
          for (final line in lines) {
            if (line.startsWith('#') || line.trim().isEmpty) continue;
            var raw = line;
            try {
              raw = Uri.decodeComponent(raw);
            } catch (_) {}
            final name = raw.contains('/') || raw.contains('\\')
                ? raw.split(RegExp(r'[\\/]')).last
                : raw;
            if (!stems.contains(_norm(name))) missing++;
          }
        }
      }
    }
    return (missing: missing, bytes: missing * avg);
  }

  /// 與 pipeline / 下載落檔一致：去掉副檔名、Windows 非法字元→_、小寫。
  /// 少了這個，估計會把「已存在」誤判成缺失（實測 11033 首，實際只缺個位數）。
  static String _norm(String pathOrName) {
    final n = pathOrName.replaceAll(RegExp(r'\.\w+$'), '');
    return n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim().toLowerCase();
  }

  /// Podcast：回 (缺幾集, 估計位元組)。
  ///
  /// ★ 必須比對本機檔案，否則會把「早就下載好的」全部算成要下載。
  ///   2026-11 實測：游庭皓的財經皓角 RSS 500 集，本機已有 498 集，
  ///   舊版直接回 500 集 / 24.5 GB，實際只缺 2 集 / 0.10 GB。
  ///
  /// 有 enclosure length 用真值；沒有就 itunes:duration × 2 MB/分。
  static Future<({int episodes, int bytes})> estimatePodcasts() async {
    final subs = ConfigService.instance.config.podcastSubscriptions;
    var missing = 0;
    var bytes = 0;
    for (final url in subs.values) {
      if (url.isEmpty) continue;
      // 本機路徑型「訂閱」（補習班音檔）不是 RSS，直接跳過
      final u = url.toLowerCase();
      if (!u.startsWith('http://') && !u.startsWith('https://')) continue;

      // 本機該節目的檔名（正規化後）
      final local = <String>{};
      final showDir = _showDirFromUrl(url);
      final dir = Directory(showDir);
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            final n = _normText(e.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), ''));
            if (n.isNotEmpty) local.add(n);
          }
        }
      }

      try {
        final r = await http
            .get(Uri.parse(url),
                headers: {'User-Agent': 'Mozilla/5.0'})
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) continue;
        final xml = r.body;
        for (final m in RegExp(r'<item>(.*?)</item>', dotAll: true).allMatches(xml)) {
          final item = m.group(1) ?? '';
          final t = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(item);
          final title = (t?.group(1) ?? '').trim();
          final key = _normText(title);
          // 命中本機就跳過（不算網路量）
          if (key.isNotEmpty) {
            var hit = local.contains(key);
            if (!hit && key.length > 12) {
              for (final n in local) {
                if (n.contains(key) || key.contains(n)) { hit = true; break; }
              }
            }
            if (hit) continue;
          }
          missing++;
          final len = RegExp(r'length="(\d+)"').firstMatch(item);
          if (len != null) {
            bytes += int.tryParse(len.group(1)!) ?? 0;
          } else {
            final dur = RegExp(
                    r'<itunes:duration>(\d+):(\d+):(\d+)</itunes:duration>')
                .firstMatch(item);
            if (dur != null) {
              final secs = int.parse(dur.group(1)!) * 3600 +
                  int.parse(dur.group(2)!) * 60 +
                  int.parse(dur.group(3)!);
              bytes += secs ~/ 60 * podcastBytesPerMinute;
            } else {
              bytes += 30 * podcastBytesPerMinute; // 未知長度，當 30 分鐘
            }
          }
        }
      } catch (_) {}
    }
    return (episodes: missing, bytes: bytes);
  }

  /// 從 RSS URL 推回本機節目資料夾（podcasts/<名稱>/）。
  /// 訂閱的 key 就是節目名，這裡用 url 反查；找不到就回空字串（= 不比對）。
  static String _showDirFromUrl(String url) {
    try {
      final subs = ConfigService.instance.config.podcastSubscriptions;
      for (final e in subs.entries) {
        if (e.value == url) {
          return '${ConfigService.instance.config.podcastsPath}'
              '${Platform.pathSeparator}${e.key}';
        }
      }
    } catch (_) {}
    return '';
  }

  /// 正規化：小寫、`/` 與 `\` 視為底線、去掉所有非字母數字（空白/標點/底線）。
  /// 本機檔名會把標題裡的 `/` 換成 `_`，不統一就都對不上（實測只認到 3/500）。
  static String _normText(String s) {
    final t = s.toLowerCase().replaceAll('/', '_').replaceAll('\\', '_');
    final sb = StringBuffer();
    for (final r in t.runes) {
      final ch = String.fromCharCode(r);
      if (RegExp(r'[a-z0-9\u4e00-\u9fff]').hasMatch(ch)) sb.write(ch);
    }
    return sb.toString();
  }
}
