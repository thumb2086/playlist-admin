import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'config_service.dart';

class SpotifyTrackMeta {
  final String title;
  final String artist;
  final String? album;
  final String? releaseDate;
  final String? coverUrl;
  SpotifyTrackMeta({
    required this.title,
    required this.artist,
    this.album,
    this.releaseDate,
    this.coverUrl,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    if (album != null) 'album': album,
    if (releaseDate != null) 'release_date': releaseDate,
    if (coverUrl != null) 'cover_url': coverUrl,
  };
}

class SpotifyScraper {
  static const _cn2en = {
    '郭靜': 'Claire Kuo', '蔡依林': 'Jolin Tsai', '盧廣仲': 'Crowd Lu',
    '曾沛慈': 'Pets Tseng', '王艷薇': 'Evangeline Wong', '胡恂舞': 'Sabrina Hu',
    '周興哲': 'Eric Chou', '孫盛希': 'Shi Shi', '文慧如': 'Boon Hui Lu',
    '陳忻玥': 'Vicky Chen', '邱鋒澤': 'Feng Ze', '艾薇': 'Ivy',
    '幻藍小熊': 'GENBLUE', '利比': 'LBI', '連穎': 'Erin',
    '李芷婷': 'Eleanor', '白安': 'Ann Bai', '王詩安': 'Diana Wang',
    '陳威全': 'Ethan', '持修': 'Chih Siou', '羅志祥': 'Show Luo',
    '陳零九': 'Nine Chen', '九澤CP': 'Nine Ze CP',
    '告五人': 'Accusefive', '理想混蛋': 'Bestards',
    '魏如萱': 'Waa Wei', '魏如昀': 'Queen Wei',
  };

  String _toEnglish(String name) => _cn2en[name] ?? name;

  String _englishDisplayName(String raw) {
    if (!raw.contains(' - ')) return raw;
    final idx = raw.lastIndexOf(' - ');
    return '${raw.substring(0, idx)} - ${_toEnglish(raw.substring(idx + 3).trim())}';
  }

  final void Function(String) log;
  final String playlistsPath;
  final String libraryPath;
  Map<String, String>? _mp3Index;

  SpotifyScraper({required this.log, required this.playlistsPath, this.libraryPath = ''});

  Future<void> _buildIndex() async {
    if (_mp3Index != null || libraryPath.isEmpty) return;
    log('  掃描音樂庫建立檔案索引…');
    final mp3 = <String, String>{};

    Future<void> scanDir(Directory dir) async {
      if (!await dir.exists()) return;
      await for (final f in dir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          final low = f.path.toLowerCase();
          if (!low.endsWith('.mp3')) continue;
          // Podcast audio is not part of the music library.
          if (low.contains('podcasts') || low.contains('podcast_rag')) continue;
          final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
          if (!mp3.containsKey(stem)) mp3[stem] = f.path;
        }
      }
    }

    await scanDir(Directory(libraryPath));
    for (final sub in ['mp3', 'flac']) {
      await scanDir(Directory('$libraryPath\\$sub'));
    }
    _mp3Index = mp3;
    log('  音檔索引完成: MP3 ${mp3.length}');
  }

  String? _findAudioFile(String trackName, {Map<String, String>? index}) {
    final ix = index ?? _mp3Index;
    if (ix == null) return null;
    final stem = trackName.toLowerCase().trim();
    if (ix.containsKey(stem)) return ix[stem];
    if (stem.contains(' - ')) {
      final parts = stem.split(' - ');
      if (parts.length >= 2) {
        final reversed = '${parts[1]} - ${parts[0]}';
        if (ix.containsKey(reversed)) return ix[reversed];
        final titlePart = parts[0].trim();
        if (titlePart.length >= 2) {
          final matchedKey = ix.keys.cast<String>().where((k) =>
              k.startsWith(titlePart) || k.contains(' $titlePart ')).firstOrNull;
          if (matchedKey != null) return ix[matchedKey];
        }
      }
    }
    return null;
  }

  Future<Map<String, List<String>>> scrapeAll(List<String> urls, {bool writeM3u8 = true}) async {
    final results = <String, List<String>>{};
    int processed = 0;
    for (final url in urls) {
      processed++;
      log('[$processed/${urls.length}] 處理: $url');
      try {
        final result = await _scrapeOne(url, writeM3u8: writeM3u8);
        if (result != null) results[result.$1] = result.$2;
      } catch (e) {
        log('  錯誤: $e');
      }
    }
    return results;
  }

  Map<String, dynamic>? _getPath(Map<String, dynamic> obj, List<String> keys) {
    var current = obj;
    for (final k in keys) {
      if (current.containsKey(k) && current[k] is Map<String, dynamic>) {
        current = current[k] as Map<String, dynamic>;
      } else {
        return null;
      }
    }
    return current;
  }

  /// 歌單名進檔案系統前消毒：Spotify 回傳含 /\: 或 .. 會寫錯目錄。
  /// 只用在拼路徑，map key 沿用原始名（rename 比對邏輯不變）。
  static String _safePlName(String name) => name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<(String, List<String>)?> _scrapeOne(String url, {bool writeM3u8 = true}) async {
    final spId = url.split('playlist/').last.split('?').first;
    final embedUrl = 'https://open.spotify.com/embed/playlist/$spId';

    log('  連線到 Spotify Embed…');
    final resp = await http.get(Uri.parse(embedUrl), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.5',
    }).timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      log('  HTTP ${resp.statusCode}');
      return null;
    }

    final doc = parse(resp.body);
    String? plName;
    final tracks = <String>[];

    // Try __NEXT_DATA__ first (newer Spotify embed format)
    final nextData = doc.querySelector('script#__NEXT_DATA__');
    if (nextData != null) {
      try {
        final data = jsonDecode(nextData.text) as Map<String, dynamic>;
        final entity = _getPath(data, ['props', 'pageProps', 'state', 'data', 'entity']);
        if (entity != null) {
          plName = (entity['name'] as String?)?.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202f\u2060-\u206f\ufeff]'), '').trim();
          final trackList = (entity['trackList'] ?? entity['tracks']) as List<dynamic>?;
          if (trackList != null) {
            _ensureCacheDir();
            for (final item in trackList) {
              final track = (item is Map<String, dynamic>) ? (item['track'] as Map<String, dynamic>? ?? item) : null;
              if (track == null) continue;
              final name = track['name'] as String? ?? track['title'] as String?;
              if (name == null) continue;
              final artists = (track['artists'] as List<dynamic>?)
                      ?.map((a) => (a as Map<String, dynamic>)['name'] as String?)
                      .where((a) => a != null)
                      .join(', ') ??
                  (track['subtitle'] as String?);
              final displayName = (artists != null && artists.isNotEmpty) ? '$name - $artists' : name;
              final engName = _englishDisplayName(displayName);
              tracks.add(engName);
              await _saveTrackCache(engName, name, _toEnglish(artists?.trim() ?? ''), track);
            }
          }
        }
      } catch (_) {
      }
    }

    // Fallback: try old script[type="application/json"] format
    if (plName == null || tracks.isEmpty) {
      final scripts = doc.querySelectorAll('script[type="application/json"]');
      for (final script in scripts) {
        try {
          final json = jsonDecode(script.text) as Map<String, dynamic>;
          final state = json['state'] as Map<String, dynamic>?;
          if (state == null) continue;
          final playlist = state['playlist'] as Map<String, dynamic>?;
          if (playlist == null) continue;
          plName = (playlist['name'] as String?)?.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202f\u2060-\u206f\ufeff]'), '').trim();
          final items = playlist['items'] as List<dynamic>?;
          if (items == null) continue;

          _ensureCacheDir();
          for (final item in items) {
            final track = item['track'] as Map<String, dynamic>?;
            if (track == null) continue;
            final artists = (track['artists'] as List<dynamic>?)
                    ?.map((a) => (a as Map<String, dynamic>)['name'] as String?)
                    .where((a) => a != null)
                    .join(', ') ?? '';
            final title = track['name'] as String? ?? '';
            final displayName = artists.isNotEmpty ? '$title - $artists' : title;
            final engName = _englishDisplayName(displayName);
            tracks.add(engName);
            await _saveTrackCache(engName, title, _toEnglish(artists.trim()), track);
          }
          break;
        } catch (_) {}
      }
    }

    if (plName == null || tracks.isEmpty) {
      log('  無法解析歌單');
      if (plName != null) {
        final emptyFile = File('$playlistsPath\\${_safePlName(plName)}.m3u8');
        if (await emptyFile.exists()) {
          await emptyFile.delete();
        }
      }
      return null;
    }

    log('  歌單: $plName, ${tracks.length} 首');

    if (writeM3u8) {
      // Build audio index to resolve track names to file paths
      await _buildIndex();

      final m3uPath = '$playlistsPath\\${_safePlName(plName)}.m3u8';
      await Directory(playlistsPath).create(recursive: true);

      // Clean up old M3U8 file if playlist was renamed
      final oldName = ConfigService.instance.config.urlNames[url];
      if (oldName != null && oldName != plName) {
        final oldFile = File('$playlistsPath\\$oldName.m3u8');
        if (await oldFile.exists()) {
          await oldFile.delete();
          log('  已清理舊歌單檔: $oldName.m3u8');
        }
      }

      final buffer = StringBuffer('#EXTM3U\n');
      int resolved = 0;
      for (final t in tracks) {
        final matched = _findAudioFile(t);
        if (matched != null) {
          // Use local filename (no ext) as EXTINF title — avoids commas & encoding issues
          final localName = File(matched).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          buffer.writeln('#EXTINF:-1,$localName');
          // Write raw relative path from Playlists dir — Echo Nightly does NOT
          // decode %XX escapes, so percent-encoding breaks playback.
          final absPath = File(matched).absolute.path;
          final absPl = File(m3uPath).parent.absolute.path;
          String relPath;
          try {
            relPath = _relativePath(absPath, absPl);
          } catch (_) {
            relPath = matched;
          }
          buffer.writeln(relPath);
          resolved++;
        } else {
          // Write unmatched track too — snapshot needs full track list for download step.
          buffer.writeln('#EXTINF:-1,$t');
          buffer.writeln('#NEEDS_DOWNLOAD:$t');
        }
      }
      await File(m3uPath).writeAsString(buffer.toString(), flush: true);
      log('  已儲存: $plName.m3u8 (已解析路徑: $resolved/${tracks.length})');
    }

    // Update config with the real playlist name
    ConfigService.instance.config.urlNames[url] = plName;
    // 必須 await：併發 scrape 下不 await 會丟失 urlNames 更新。
    await ConfigService.instance.save();
    return (plName, tracks);
  }

  String _relativePath(String absPath, String relativeTo) {
    final absParts = absPath.replaceAll('\\', '/').split('/');
    final relParts = relativeTo.replaceAll('\\', '/').split('/');
    int common = 0;
    while (common < absParts.length && common < relParts.length &&
        absParts[common].toLowerCase() == relParts[common].toLowerCase()) {
      common++;
    }
    final up = List.filled(relParts.length - common, '..');
    final down = absParts.sublist(common);
    return [...up, ...down].join('/');
  }

  void _ensureCacheDir() {
    final base = ConfigService.instance.config.basePath;
    if (base.isEmpty) return;
    final dir = Directory('$base\\spotify_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  String _cacheDir() =>
      '${ConfigService.instance.config.basePath}\\spotify_cache';

  Future<void> _saveTrackCache(String displayName, String title, String artists, Map<String, dynamic> track) async {
    try {
      final album = track['album'] as Map<String, dynamic>?;
      String? albumName;
      String? releaseDate;
      String? coverUrl;

      if (album != null) {
        albumName = album['name'] as String?;
        releaseDate = (album['release_date'] ?? album['date']) as String?;
        final images = album['images'] as List<dynamic>?;
        if (images != null && images.isNotEmpty) {
          final img = images[0] as Map<String, dynamic>?;
          coverUrl = img?['url'] as String?;
        }
      }

      final meta = SpotifyTrackMeta(
        title: title,
        artist: artists,
        album: albumName,
        releaseDate: releaseDate,
        coverUrl: coverUrl,
      );

      final cleanName = _sanitize(displayName);
      final file = File('${_cacheDir()}\\$cleanName.json');
      await file.writeAsString(jsonEncode(meta.toJson()), flush: true);
    } catch (_) {}
  }

  String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
