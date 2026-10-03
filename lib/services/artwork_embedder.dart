import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config_service.dart';
import 'cover_cache.dart';
import 'spotify_gql_client.dart';
import 'spotify_session.dart';

/// 內嵌封面：YouTube 音源本來就沒圖（ffmpeg 下載還帶 -vn 主動丟掉），
/// 所以下載鏈從不嵌圖，app 才會全靠 Spotify URL 封面。
/// 這裡提供統一入口：下載完成後呼一次 embedForFile，全庫回填走 backfill。
enum ArtworkResult { embedded, skippedHasArt, noCover, failed }

class ArtworkEmbedder {
  static ArtworkEmbedder? _instance;
  static ArtworkEmbedder get instance => _instance ??= ArtworkEmbedder._();
  ArtworkEmbedder._();

  String _ffprobePath() {
    try {
      final ff = ConfigService.instance.config.resolvedFfmpegPath;
      if (ff.endsWith('.exe') || ff.contains(Platform.pathSeparator)) {
        final cand =
            '${File(ff).parent.path}${Platform.pathSeparator}ffprobe.exe';
        if (File(cand).existsSync()) return cand;
      }
    } catch (_) {}
    return 'ffprobe';
  }

  String _ffmpegPath() {
    try {
      return ConfigService.instance.config.resolvedFfmpegPath;
    } catch (_) {
      return 'ffmpeg';
    }
  }

  /// 是否已有內嵌圖片（任一 video/image stream 或 attached_pic）。
  Future<bool> hasArtwork(String mp3path) async {
    try {
      final r = await Process.run(_ffprobePath(), [
        '-v', 'quiet', '-print_format', 'json', '-show_streams', mp3path,
      ]);
      if (r.exitCode != 0) return false;
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = j['streams'] as List? ?? [];
      return streams.any((s) =>
          s is Map &&
          (s['codec_type'] == 'video' ||
              s['codec_type'] == 'image' ||
              (s['disposition'] as Map?)?['attached_pic'] == 1));
    } catch (_) {
      return false;
    }
  }

  /// 檔名 stem 拆 title/artist（慣例「曲名 - 歌手」，與 _titleFromPath 一致）。
  static (String title, String artist) splitStem(String stem) {
    final sep = stem.split(' - ');
    if (sep.length < 2) return (stem, '');
    return (sep.first, sep.sublist(1).join(' - '));
  }

  /// 對單檔嵌圖。已有圖直接 skip；找不到封面回 noCover；失敗回 failed。
  /// coverUrl 直接給可跳過 Spotify 搜尋（下載路徑已知時用）。
  Future<ArtworkResult> embedForFile(String mp3path,
      {String? title, String? artist, String? coverUrl}) async {
    if (!await File(mp3path).exists()) return ArtworkResult.failed;
    if (await hasArtwork(mp3path)) return ArtworkResult.skippedHasArt;
    final stem = File(mp3path)
        .uri
        .pathSegments
        .last
        .replaceAll(RegExp(r'\.\w+$'), '');
    final parts = splitStem(stem);
    final t = (title != null && title.isNotEmpty) ? title : parts.$1;
    final a = (artist != null && artist.isNotEmpty) ? artist : parts.$2;

    String? url = (coverUrl != null && coverUrl.isNotEmpty) ? coverUrl : null;
    url ??= await _resolveCoverUrl(t, a);
    if (url == null || url.isEmpty) return ArtworkResult.noCover;
    return await embedFromUrl(mp3path, url);
  }

  /// 封面解析：磁碟快取 → Spotify 搜一次（驗收曲名相符才收，寫透快取）。
  Future<String?> _resolveCoverUrl(String title, String artist) async {
    try {
      final cache = await CoverCache.load();
      final e = cache[CoverCache.key(null, title, artist)];
      final cached = (e is Map) ? e['c'] as String? : null;
      if (cached != null && cached.isNotEmpty) return cached;
    } catch (_) {}
    if (!SpotifySession.instance.isLoggedIn) return null;
    try {
      final q = '$title $artist'.trim();
      if (q.isEmpty) return null;
      final data = await SpotifyGqlClient().searchTracks(q, limit: 5);
      final tracks = SpotifyTrackItem.parseSearchTracks(data);
      if (tracks.isEmpty) return null;
      final want = CoverCache.norm(title);
      SpotifyTrackItem? pick;
      for (final t in tracks) {
        final nt = CoverCache.norm(t.name);
        if (want.length >= 2 &&
            nt.length >= 2 &&
            (nt.contains(want) || want.contains(nt))) {
          pick = t;
          break;
        }
      }
      pick ??= tracks.first;
      final url = pick.coverUrl;
      if (url != null && url.isNotEmpty) {
        try {
          final cache = await CoverCache.load();
          cache[CoverCache.key(null, title, artist)] = {
            'c': url,
            'd': pick.durationMs,
            'a': pick.album,
          };
          await CoverCache.save(cache);
        } catch (_) {}
      }
      return url;
    } catch (_) {
      return null;
    }
  }

  Future<ArtworkResult> embedFromUrl(String mp3path, String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        return ArtworkResult.failed;
      }
      return await embedFromBytes(mp3path, resp.bodyBytes);
    } catch (_) {
      return ArtworkResult.failed;
    }
  }

  /// ffmpeg remux 嵌圖（音訊 copy 不重編碼，幾秒內完成）。
  /// 用 Process.start + 超時殺樹：Process.run 卡住時殺不掉。
  Future<ArtworkResult> embedFromBytes(String mp3path, List<int> img) async {
    final tmp = '$mp3path.artwork.mp3';
    final imgTmp = '$mp3path.cover.tmp';
    Process? proc;
    try {
      await File(imgTmp).writeAsBytes(img, flush: true);
      proc = await Process.start(_ffmpegPath(), [
        '-y', '-i', mp3path, '-i', imgTmp,
        '-map', '0:a', '-map', '1:0',
        '-c:a', 'copy', '-c:v', 'mjpeg',
        '-id3v2_version', '3',
        '-metadata:s:v', 'title=Album cover',
        '-metadata:s:v', 'comment=Cover (front)',
        tmp,
      ], runInShell: false);
      unawaited(proc.stdout.drain());
      unawaited(proc.stderr.drain());
      final code = await proc.exitCode.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _killTree(proc!);
          return -1;
        },
      );
      if (code != 0) return ArtworkResult.failed;
      if (!await hasArtwork(tmp)) return ArtworkResult.failed;
      await File(mp3path).delete();
      await File(tmp).rename(mp3path);
      return ArtworkResult.embedded;
    } catch (_) {
      return ArtworkResult.failed;
    } finally {
      try {
        if (await File(imgTmp).exists()) await File(imgTmp).delete();
      } catch (_) {}
      try {
        if (await File(tmp).exists() && !await File(mp3path).exists()) {
          await File(tmp).delete();
        }
      } catch (_) {}
    }
  }

  void _killTree(Process proc) {
    try {
      if (Platform.isWindows) {
        Process.run(
            'taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill(ProcessSignal.sigterm);
      }
    } catch (_) {}
  }

  /// 配對單一 stem 到 Spotify 曲目（與詳情頁同 tiers：全等雙序 →
  /// 不分順序 both-parts → 曲名單獨），回傳命中或 null。
  static SpotifyTrackItem? matchTrack(
      String stem, List<SpotifyTrackItem> tracks) {
    final ns = CoverCache.norm(stem);
    final parts = stem.split(' - ');
    final localTitle = parts.first;
    final localArtist =
        parts.length > 1 ? parts.sublist(1).join(' - ') : '';
    for (final t in tracks) {
      if (t.coverUrl == null || t.coverUrl!.isEmpty) continue;
      if (ns == CoverCache.norm('${t.name} - ${t.artists.join(', ')}') ||
          (t.artists.isNotEmpty &&
              ns == CoverCache.norm('${t.artists.join(', ')} - ${t.name}'))) {
        return t;
      }
    }
    for (final t in tracks) {
      if (t.coverUrl == null || t.coverUrl!.isEmpty) continue;
      final nt = CoverCache.norm(t.name);
      final na = CoverCache.norm(
          t.artists.isNotEmpty ? t.artists.first : '');
      final lt = CoverCache.norm(localTitle);
      if (nt.length >= 2 &&
          na.length >= 2 &&
          lt.contains(nt) &&
          CoverCache.norm(localArtist).contains(na)) {
        return t;
      }
    }
    for (final t in tracks) {
      if (t.coverUrl == null || t.coverUrl!.isEmpty) continue;
      final nt = CoverCache.norm(t.name);
      if (nt.length >= 3 && CoverCache.norm(stem).contains(nt)) {
        return t;
      }
    }
    return null;
  }

  static String? playlistIdFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    return RegExp(r'playlist[/:]([A-Za-z0-9]+)').firstMatch(url)?.group(1);
  }

  /// 批次暖快取：每份 Spotify 歌單一次 fetch，配對全部待嵌 stem 並寫快取。
  /// 之後逐檔流程走快取命中，只有真剩餘才打搜尋。
  Future<int> warmCacheFromPlaylists(
    List<String> stems, {
    required void Function(String file) onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!SpotifySession.instance.isLoggedIn) return 0;
    final urlNames = ConfigService.instance.config.urlNames;
    if (urlNames.isEmpty) return 0;
    final gql = SpotifyGqlClient();
    final all = <SpotifyTrackItem>[];
    final seenUri = <String>{};
    for (final e in urlNames.entries) {
      if (isCancelled?.call() == true) break;
      final id = playlistIdFromUrl(e.key);
      if (id == null) continue;
      onProgress('暖快取：${e.value}…');
      try {
        var offset = 0;
        while (all.length < 3000) {
          final data =
              await gql.fetchPlaylist(id, offset: offset, limit: 50);
          final tracks = SpotifyTrackItem.parsePlaylistTracks(data);
          if (tracks.isEmpty) break;
          for (final t in tracks) {
            if (t.uri.isNotEmpty && seenUri.add(t.uri)) all.add(t);
          }
          if (tracks.length < 50) break;
          offset += 50;
        }
      } catch (_) {}
    }
    if (all.isEmpty) return 0;
    var warmed = 0;
    try {
      final cache = await CoverCache.load();
      for (final s in stems) {
        final m = matchTrack(s, all);
        if (m?.coverUrl == null || m!.coverUrl!.isEmpty) continue;
        final parts = splitStem(s);
        cache[CoverCache.key(null, parts.$1, parts.$2)] = {
          'c': m.coverUrl,
          'd': m.durationMs,
          'a': m.album,
        };
        warmed++;
      }
      await CoverCache.save(cache);
    } catch (_) {}
    return warmed;
  }
  /// Serial 為主（Spotify 限流）+ ffprobe 預檢並行；可取消；冪等可重跑。
  Future<Map<String, int>> backfill({
    required void Function(int done, int total, String file) onProgress,
    bool Function()? isCancelled,
  }) async {
    var embedded = 0, skipped = 0, noCover = 0, failed = 0;
    final files = <String>[];
    try {
      final dir = Directory(ConfigService.instance.config.musicPath);
      if (await dir.exists()) {
        await for (final f in dir.list(recursive: true, followLinks: false)) {
          if (f is File && f.path.toLowerCase().endsWith('.mp3')) {
            files.add(f.path);
          }
        }
      }
    } catch (_) {}
    files.sort();
    final total = files.length;

    // 預檢有圖與否（8 並行，ffprobe 很快）。
    final needsArt = <String>[];
    for (int i = 0; i < files.length; i += 8) {
      if (isCancelled?.call() == true) break;
      final chunk = files.sublist(i, (i + 8).clamp(0, files.length));
      final results = await Future.wait(chunk.map((p) async {
        try {
          return await hasArtwork(p).timeout(const Duration(seconds: 15));
        } catch (_) {
          return false;
        }
      }));
      for (int j = 0; j < chunk.length; j++) {
        if (results[j]) {
          skipped++;
        } else {
          needsArt.add(chunk[j]);
        }
      }
      onProgress(i + chunk.length, total,
          '預檢中… (${needsArt.length} 首待嵌)');
    }

    // 批次暖快取（歌單整批配對，省掉上千次逐曲搜尋）。
    if (needsArt.isNotEmpty && (isCancelled?.call() != true)) {
      final checked = files.length - needsArt.length;
      final warmStems = needsArt
          .map((p) => File(p)
              .uri
              .pathSegments
              .last
              .replaceAll(RegExp(r'\.\w+$'), ''))
          .toList();
      final warmed = await warmCacheFromPlaylists(
        warmStems,
        onProgress: (f) => onProgress(checked, total, f),
        isCancelled: isCancelled,
      );
      onProgress(checked, total, '暖快取完成（$warmed 首已定位封面）');
    }

    // 圖片位元組記憶體去重：同專輯多首歌只下載一次。
    final imgCache = <String, List<int>>{};
    Future<List<int>?> fetchImg(String url) async {
      if (imgCache.containsKey(url)) return imgCache[url];
      try {
        final resp = await http
            .get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'})
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          imgCache[url] = resp.bodyBytes;
          return resp.bodyBytes;
        }
      } catch (_) {}
      return null;
    }

    int done2 = files.length - needsArt.length;
    for (final p in needsArt) {
      if (isCancelled?.call() == true) break;
      done2++;
      final name =
          File(p).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      onProgress(done2, total, name);
      try {
        if (await hasArtwork(p)) {
          skipped++;
          continue;
        }
        final parts = splitStem(name);
        String? url;
        try {
          final cache = await CoverCache.load();
          final e = cache[CoverCache.key(null, parts.$1, parts.$2)];
          url = (e is Map) ? e['c'] as String? : null;
        } catch (_) {}
        url ??= await _resolveCoverUrl(parts.$1, parts.$2);
        if (url == null || url.isEmpty) {
          noCover++;
          continue;
        }
        final img = await fetchImg(url);
        if (img == null) {
          failed++;
          continue;
        }
        final r = await embedFromBytes(p, img);
        if (r == ArtworkResult.embedded) {
          embedded++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    return {
      'total': total,
      'embedded': embedded,
      'skipped': skipped,
      'noCover': noCover,
      'failed': failed,
    };
  }
}
