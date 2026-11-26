import 'dart:convert';
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
  ///
  /// ★ 來源必須與 pipeline 的 download 步驟**完全一致**，否則數字對不上。
  ///   2026-11 實測：這裡讀 .m3u8 說缺 528 首，pipeline 讀 snapshot_cache.json
  ///   只缺 38 首 —— m3u8 是 step 2 產物、會過時；snapshot 才是 scrape 的真相。
  ///   現在改成讀 snapshot_cache.json 的 playlists[].tracks，並用同一套
  ///   _normSong（非法字元→_、小寫）比對 musicPath 全遞迴掃描。
  static Future<({int missing, int bytes})> estimateMusic({int? avgBytesPerTrack}) async {
    final cfg = ConfigService.instance.config;
    final avg = avgBytesPerTrack ?? defaultMusicBytesPerTrack;

    final allSongs = <String>{};
    final snapFile = File('${cfg.basePath}${Platform.pathSeparator}snapshot_cache.json');
    try {
      if (await snapFile.exists()) {
        final snap = jsonDecode(await snapFile.readAsString()) as Map<String, dynamic>;
        final playlists = snap['playlists'] as Map<String, dynamic>? ?? {};
        for (final pl in playlists.values) {
          final tracks = (pl as Map<String, dynamic>)['tracks'] as List<dynamic>? ?? [];
          for (final t in tracks) {
            final s = t.toString().trim();
            if (s.isNotEmpty) allSongs.add(s);
          }
        }
      }
    } catch (_) {}

    // 本機：musicPath 全遞迴（與 pipeline 同一個 _normSong）
    final existing = <String>{};
    final musicDir = Directory(cfg.musicPath);
    if (await musicDir.exists()) {
      await for (final e in musicDir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          // 先去副檔名再比（_normSong 只處理非法字元，不含去副檔名）
          final base = File(e.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          existing.add(_normSong(base));
        }
      }
    }

    var missing = 0;
    for (final s in allSongs) {
      if (!existing.contains(_normSong(s))) missing++;
    }
    return (missing: missing, bytes: missing * avg);
  }

  /// 與 pipeline 完全相同：去副檔名、Windows 非法字元→_、小寫。
  static String _normSong(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim().toLowerCase();

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
    for (final entry in subs.entries) {
      final url = entry.value;
      if (url.isEmpty) continue;
      // 本機路徑型「訂閱」（補習班音檔）不是 RSS，直接跳過
      final u = url.toLowerCase();
      if (!u.startsWith('http://') && !u.startsWith('https://')) continue;

      // 本機該節目的檔名（正規化後）
      final local = <String>{};
      // 直接用訂閱名稱當資料夾（不需 url 反查，避免名稱正規化不一致）
      final dir = Directory('${ConfigService.instance.config.podcastsPath}'
          '${Platform.pathSeparator}${entry.key}');
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            // 用 e.path 取檔名，不可用 e.uri.pathSegments（uri 會把中文/空白
            // 百分號編碼，正規化後永遠對不上標題 → 全部誤判成缺）
            final base = e.path
                .split(RegExp(r'[\\\\/]'))
                .last
                .replaceAll(RegExp(r'\.\w+$'), '');
            final n = _normText(base);
            if (n.isNotEmpty) local.add(n);
          }
        }
      }

      var showBytes = 0;
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
          // RSS 常見 <title><![CDATA[...]]></title>：不先去 CDATA 包裝，
          // 正規化後會多一截 "cdata" 前綴 → 跟本機檔名永遠對不上（實測 490 誤判）
          final rawTitle = (t?.group(1) ?? '')
              .replaceAll('<![CDATA[', '')
              .replaceAll(']]>', '')
              .trim();
          final key = _normText(rawTitle);
          // 沒有標題（或正規化後空）的項目不計入，否則會虛增缺集數
          if (key.isEmpty) continue;
          // 完全相等優先，再退回雙向 contains（本機檔名可能帶前綴）。
          // 注意：contains 只在同一個節目的 local 集合內比，且要求 key 非空，
          // 避免先前 Python 版那種「不相關也配成命中」的假陽性。
          if (local.contains(key)) continue;
          var hit = false;
          for (final n in local) {
            if (n.contains(key) || key.contains(n)) { hit = true; break; }
          }
          if (hit) continue;
          missing++;
          final len = RegExp(r'length="(\d+)"').firstMatch(item);
          if (len != null) {
            showBytes += int.tryParse(len.group(1)!) ?? 0;
          } else {
            final dur = RegExp(
                    r'<itunes:duration>(\d+):(\d+):(\d+)</itunes:duration>')
                .firstMatch(item);
            if (dur != null) {
              final secs = int.parse(dur.group(1)!) * 3600 +
                  int.parse(dur.group(2)!) * 60 +
                  int.parse(dur.group(3)!);
              showBytes += secs ~/ 60 * podcastBytesPerMinute;
            } else {
              showBytes += 30 * podcastBytesPerMinute; // 未知長度，當 30 分鐘
            }
          }
        }
      } catch (_) {}
      bytes += showBytes;
    }
    return (episodes: missing, bytes: bytes);
  }

  /// 正規化：小寫、`/` 與 `\` 視為底線、去掉所有非字母數字（空白/標點/底線）。
  /// 本機檔名會把標題裡的 `/` 換成 `_`，不統一就都對不上（實測只認到 3/500）。
  // 與 Python 參照的 ch.isalnum() 等價：拉丁字母數字 + CJK + 日文假名 + 韓文
  static final _keepChar = RegExp(
      r'[0-9A-Za-z\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af\u3400-\u4dbf]');

  static String _normText(String s) {
    final t = s.toLowerCase().replaceAll('/', '_').replaceAll('\\', '_');
    final sb = StringBuffer();
    for (final r in t.runes) {
      final ch = String.fromCharCode(r);
      if (_keepChar.hasMatch(ch)) sb.write(ch);
    }
    var out = sb.toString();
    // RSS 的 CDATA 包裝正規化後會殘留 cdata 前綴（實測導致 486 集誤判成缺）
    if (out.startsWith('cdata')) out = out.substring(5);
    return out;
  }
}
