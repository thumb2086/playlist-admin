import 'dart:convert';
import 'dart:io';
import 'config_service.dart';
import 'cover_cache.dart';
import 'metadata_reader.dart';
import 'artist_names.dart';

/// 檔名 stem（不含副檔名）——cache key 兜底用。
String fileNameFor(String path) =>
    File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');

class MetadataEnricher {
  final void Function(String) log;
  final String libraryPath;

  MetadataEnricher({required this.log, required this.libraryPath});

  Future<void> enrichAll({void Function(int, int)? onProgress}) async {
    log('🔍 掃描缺少 metadata 的檔案…');
    final files = await _scanMissingMetadata();
    if (files.isEmpty) {
      log('✅ 所有檔案都有完整 metadata');
      return;
    }

    log('🎵 找到 ${files.length} 個檔案缺少 metadata，開始補充…');
    int success = 0;

    // spotify_cache 索引只建一次：原本每首歌都 listSync + 全讀全 parse，
    // O(歌×快取檔) 的同步 IO 全卡在主 thread 上。
    final cacheIndex = await _loadSpotifyCacheIndex();

    for (int i = 0; i < files.length; i++) {
      final path = files[i];
      try {
        final ok = await _enrichFile(path, cacheIndex);
        if (ok) success++;
      } catch (e) {
        log('  ❌ ${path.split('\\').last}: $e');
      }
      if (onProgress != null) onProgress(i + 1, files.length);
      if (i % 10 == 9 || i == files.length - 1) {
        log('  進度: ${i + 1}/${files.length} (成功: $success)');
      }
    }
    log('🎉 Metadata 補充完成: $success/${files.length}');
  }

  /// 把 ID3 裡的英文歌手名轉成中文（ArtistNames 對照表有的才轉）。
  ///
  /// 為什麼要獨立流程：enrichAll 只補「缺的值」，而這批檔案的 artist
  /// 早就寫了英文（非空）→ 不會被覆寫。這個流程專治「值存在但語言錯」。
  /// 只改 artist tag，title/album/date/封面一律不動（音訊 copy）。
  Future<int> localizeArtists({void Function(int done, int total)? onProgress}) async {
    log('🌏 掃描 artist 英文名（轉中文）…');
    final files = <String>[];
    try {
      final dir = Directory(libraryPath);
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.mp3')) {
            files.add(e.path);
          }
        }
      }
    } catch (_) {}
    files.sort();
    final total = files.length;
    if (total == 0) {
      log('沒有 mp3 可處理');
      return 0;
    }
    var changed = 0;
    for (int i = 0; i < files.length; i++) {
      final p = files[i];
      try {
        final meta = await MetadataReader.read(p);
        final cur = (meta.artist ?? '').trim();
        // 空 → 不處理（enrichAll 負責）；已是中文 → 跳過。
        if (cur.isEmpty ||
            RegExp(r'[\u4e00-\u9fff]').hasMatch(cur)) {
          onProgress?.call(i + 1, total);
          continue;
        }
        final zh = ArtistNames.toDisplayList(cur);
        if (zh == cur || zh.isEmpty) {
          onProgress?.call(i + 1, total);
          continue;
        }
        if (await _applyMetadata(p, meta.title, zh, meta.album, null, null)) {
          changed++;
          log('  ✅ ${File(p).uri.pathSegments.last}: $cur → $zh');
        }
      } catch (_) {}
      onProgress?.call(i + 1, total);
      if (i % 50 == 0) {
        log('  進度: ${i + 1}/$total（已轉 $changed）');
        await Future<void>.delayed(Duration.zero);
      }
    }
    log('🎉 artist 中文化完成：$changed/$total');
    return changed;
  }

  Future<List<String>> _scanMissingMetadata() async {
    final missing = <String>[];
    final dir = Directory(libraryPath);
    if (!await dir.exists()) return missing;

    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final low = e.path.toLowerCase();
      if (!low.endsWith('.mp3') && !low.endsWith('.m4a') && !low.endsWith('.flac')) continue;

      final meta = await MetadataReader.read(e.path);
      if (meta.title == null || meta.title!.isEmpty || meta.artist == null || meta.artist!.isEmpty) {
        missing.add(e.path);
      }
    }
    return missing;
  }

  Future<bool> _enrichFile(String filePath, Map<String, Map<String, dynamic>> cacheIndex) async {
    final stem = File(filePath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    final meta = await MetadataReader.read(filePath);

    String? title = meta.title;
    String? artist = meta.artist;
    String? album;
    String? year;
    String? coverUrl;

    // 1. Try Spotify cache (in-memory index, no IO here)
    final cached = _lookupSpotifyCache(stem, cacheIndex);
    if (cached != null) {
      title ??= cached['title'] as String?;
      artist ??= cached['artist'] as String?;
      album ??= cached['album'] as String?;
      coverUrl ??= cached['cover_url'] as String?;
      // 年份來源依序：release_date → CoverCache 的 'y'（artwork embedder 從
      // Spotify GQL albumOfTrack.date 寫入）。只認 4 位數。
      final rd = cached['release_date'] as String?;
      if (rd != null && rd.length >= 4) {
        year = rd.substring(0, 4);
      } else {
        try {
          final cc = await CoverCache.load();
          final key = CoverCache.key(null, title ?? fileNameFor(filePath),
              artist ?? '');
          final e = cc[key];
          if (e is Map) year = e['y'] as String?;
        } catch (_) {}
      }
    }

    // 2. If still no title/artist, try to extract from filename.
    // 檔名慣例是「曲名 - 歌手」（下載時 `${name} - ${artist}`），
    // 與 _titleFromPath/_artistFromPath 一致：第一段=曲名。
    final fileName = File(filePath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    if ((title == null || title.isEmpty) && fileName.contains(' - ')) {
      final parts = fileName.split(' - ');
      if (parts.length >= 2) {
        title = parts.first.trim();
        artist = parts.sublist(1).join(' - ').trim();
      }
    }

    if (title == null || title.isEmpty) {
      title = fileName;
    }

    // Apply metadata via ffmpeg
    return _applyMetadata(filePath, title, artist, album, year, coverUrl);
  }

  /// 一次把 spotify_cache 讀進記憶體（檔名 stem → 內容），之後全是記憶體比對。
  Future<Map<String, Map<String, dynamic>>> _loadSpotifyCacheIndex() async {
    final index = <String, Map<String, dynamic>>{};
    try {
      final base = ConfigService.instance.config.basePath;
      if (base.isEmpty) return index;
      final cacheDir = Directory('$base\\spotify_cache');
      if (!await cacheDir.exists()) return index;
      await for (final f in cacheDir.list()) {
        if (f is File && f.path.endsWith('.json')) {
          try {
            final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
            final key = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
            index[key] = data;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return index;
  }

  Map<String, dynamic>? _lookupSpotifyCache(String stem, Map<String, Map<String, dynamic>> index) {
    if (index.isEmpty) return null;
    final hit = index[stem.toLowerCase()];
    if (hit != null) return hit;
    // Fuzzy fallback：只允許「長的那個包含短的」，且短的至少 6 字。
    // 舊寫法是雙向 contains 且無長度下限 → "BTS" 命中 ARIRANG、
    // "Body to Body - BTS" 配到 BTS 舊專輯 album，album 全錯。
    final stemKey = fuzzyKey(stem);
    if (stemKey.length < 6) return null;
    // 檔名「曲名 - 歌手」：曲名段拿來驗證命中，防止 artist's 短 token
    // 反向命中別的歌（Everything - BIDO 曾愷妤 曾被整筆 cache 覆蓋成
    // title=Everything/artist=BIDO，標籤錯置）。
    final stemTitle = fuzzyKey(
        stem.contains(' - ') ? stem.split(' - ').first : stem);
    for (final data in index.values) {
      final cacheKey = fuzzyKey(data['title'] as String? ?? '');
      if (cacheKey.length < 6) continue;
      final bool hit2 = stemKey.length >= cacheKey.length
          ? stemKey.contains(cacheKey)
          : cacheKey.contains(stemKey);
      if (!hit2) continue;
      // 曲名必須也相符（雙向包含，>=2 字才算），否則跳過這筆。
      if (stemTitle.length >= 2 && cacheKey.length >= 2 &&
          !stemTitle.contains(cacheKey) && !cacheKey.contains(stemTitle)) {
        continue;
      }
      return data;
    }
    return null;
  }

  /// 模糊比對用正規化 key：小寫、去空白與標點，只留字母數字。
  /// 公開是為了測試（純函式，無副作用）。
  static final _fuzzyStrip = RegExp(
      "[\\s\\-_·、,，.。!！?？:：;；\"'（）()\\[\\]【】]");
  static String fuzzyKey(String s) =>
      s.toLowerCase().replaceAll(_fuzzyStrip, '');

  Future<bool> _applyMetadata(
    String filePath,
    String? title,
    String? artist,
    String? album,
    String? year,
    String? coverUrl,
  ) async {
    try {
      final ext = filePath.toLowerCase().split('.').last;
      final tmpPath = '${filePath}_tmp.$ext';

      final cmd = <String>['ffmpeg', '-y', '-i', filePath, '-c', 'copy'];
      if (title != null && title.isNotEmpty) cmd.addAll(['-metadata', 'title=$title']);
      // artist 轉中文：Spotify embed 路徑給英文（Bestards / Claire Kuo…），
      // ArtistNames 對照表有的才轉，查不到原樣保留（不臆測日本/歐美藝人）。
      final artistOut = (artist != null && artist.isNotEmpty)
          ? ArtistNames.toDisplayList(artist)
          : artist;
      if (artistOut != null && artistOut.isNotEmpty) {
        cmd.addAll(['-metadata', 'artist=$artistOut']);
      }
      if (album != null && album.isNotEmpty) cmd.addAll(['-metadata', 'album=$album']);
      // 年份必須是 4 位數：任何其他值（空/怪字串）寧可不寫，
      // 寫壞會讓播放器顯示 1970/0000，比沒日期更糟。
      final y = year?.trim() ?? '';
      if (RegExp(r'^(1\d{3}|2\d{3})$').hasMatch(y)) {
        cmd.addAll(['-metadata', 'date=$y']);
      }
      // 有封面就一併帶過去：舊寫法只 map 0:a → 跑一次 metadata 就把封面洗掉。
      final hadArt = await _hasArtwork(filePath);
      if (hadArt) {
        final tmp2 = '$filePath.mtag.mp3';
        cmd.removeLast(); // 移除 tmpPath
        cmd.addAll(['-i', filePath, '-map', '0:a', '-map', '0:v',
          '-c:a', 'copy', '-c:v', 'mjpeg', '-id3v2_version', '3',
          '-metadata:s:v', 'title=Album cover',
          '-metadata:s:v', 'comment=Cover (front)', tmp2]);
        final r2 = await Process.run(cmd[0], cmd.sublist(1), runInShell: false);
        if (r2.exitCode != 0 || !await File(tmp2).exists()) {
          if (await File(tmp2).exists()) await File(tmp2).delete();
          return false;
        }
        await File(filePath).delete();
        await File(tmp2).rename(filePath);
        log('  ✅ 已更新 metadata: ${File(filePath).uri.pathSegments.last}');
        return true;
      }
      cmd.add(tmpPath);

      // runInShell: false：中文 artist 經 cmd.exe 會被引號/特殊符號吃掉。
      final result = await Process.run(cmd[0], cmd.sublist(1), runInShell: false);

      if (result.exitCode == 0) {
        await File(filePath).delete();
        await File(tmpPath).rename(filePath);
        log('  ✅ 已更新 metadata: ${File(filePath).uri.pathSegments.last}');
        return true;
      } else {
        if (await File(tmpPath).exists()) await File(tmpPath).delete();
        log('  ⚠️ 寫入 metadata 失敗: ${File(filePath).uri.pathSegments.last}');
        return false;
      }
    } catch (e) {
      log('  ⚠️ Metadata 寫入錯誤: $e');
      return false;
    }
  }

  /// 有沒有內嵌封面（ffprobe 找 image stream）。
  Future<bool> _hasArtwork(String path) async {
    try {
      final r = await Process.run('ffprobe', [
        '-v', 'quiet', '-print_format', 'json', '-show_streams', path,
      ], runInShell: false);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = j['streams'] as List<dynamic>? ?? [];
      return streams.any((s) =>
          (s is Map) &&
          (s['codec_type'] == 'video' || s['codec_type'] == 'image'));
    } catch (_) {
      return false;
    }
  }
}
